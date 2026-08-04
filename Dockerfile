# Pijul Nest for Cloudron.
#
# Three processes in one container: the Rust API, the SvelteKit UI under node, and
# nginx in front splitting one hostname between them by path. A fourth, nest-rank,
# runs every six hours from cron.
#
# The upstream tree is neither versioned nor released, so the build is pinned to an
# exact change hash. See docs/decisions/0001-versioning.md.

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: the client, purely so the source can be fetched at all.
# There is no GitHub mirror; the Nest lives only on Pijul's own Nest, so a pijul
# client is a build dependency before anything else can happen.
# ─────────────────────────────────────────────────────────────────────────────
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c AS fetch

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/opt/rust \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config libsodium-dev libssl-dev libzstd-dev \
        libclang-dev clang cmake curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --no-modify-path --profile minimal --default-toolchain stable \
    && rm /tmp/rustup.sh

RUN cargo install pijul --version '~1.0.0-beta' --locked

# The pin. Change all three of these and the CHANGELOG entry together, never one alone.
#
# Pinned by STATE, not by change. `pijul clone --change <hash>` is the obvious way to
# do this and it does not work against this repository: it fetches the change and its
# dependencies, then panics in pijul-core 1.0.0-beta.20 at change.rs:1663 deserialising
# a dependency whose file is not on disk (`IoHash { err: NotFound, hash: 2QMA3JQ... }`).
# `--state` produces exactly the tree we want and exits 0. Verified both ways.
ARG NEST_STATE=XPM3P75Q46MMDEOUEQXRWE5AME3SKYOXEF7GAHJDBEJXQLXZ23LAC
ARG NEST_CHANGE=SX4EP5B4JDSLV4SDIB2A43MJANAR66IHKRCK3KPNVLJIG4OCYY6QC
ARG NEST_DATE=2026-08-04
ENV HOME=/tmp
RUN pijul clone --state "${NEST_STATE}" https://nest.pijul.com/pijul/nest /src \
    && cd /src \
    && test "$(pijul log --limit 1 --hash-only | head -1)" = "${NEST_CHANGE}" \
    && printf '%s %s %s\n' "${NEST_CHANGE}" "${NEST_STATE}" "${NEST_DATE}" > /src/.upstream-change \
    && rm -rf /src/.pijul

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: build. Everything upstream's flake.nix overrides is an ordinary apt
# package, so no Nix is involved. Verified: the whole workspace builds in about a
# minute with plain cargo.
# ─────────────────────────────────────────────────────────────────────────────
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c AS build

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/opt/rust \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential pkg-config libsodium-dev libpq-dev protobuf-compiler \
        libssl-dev libzstd-dev libxxhash-dev libclang-dev clang cmake bison flex \
        curl ca-certificates unzip woff2 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --no-modify-path --profile minimal --default-toolchain stable \
    && rustup target add wasm32-unknown-unknown \
    && rm /tmp/rustup.sh

# wasm-pack, because pnpm-workspace.yaml lists identicon/pkg and identicon/pkg-node
# as members and pnpm-lock.yaml carries importers for both, yet neither directory
# exists in the tree: they are wasm-pack output. Without them `pnpm install
# --frozen-lockfile` cannot be satisfied. Upstream only ever mentions wasm-pack in
# its development shell.
RUN cargo install wasm-pack --locked

# pnpm is not on the base's PATH, but corepack is. Pinned rather than @latest so a
# rebuild months from now resolves the same package manager.
RUN corepack enable && corepack prepare pnpm@11.20.0 --activate

COPY --from=fetch /src /src
WORKDIR /src

# diesel-cli, for the migration step. It links libpq, which the base already ships.
RUN cargo install diesel_cli --no-default-features --features postgres --locked

# The Rust workspace: the `nest` API binary and the `nest-rank` periodic job.
RUN cargo build --release --locked --bin nest --bin nest-rank

# Web fonts. upstream's flake.nix is the authority here, not the version comment in
# design/fonts.css, which is one patch release behind. Both are SIL OFL 1.1.
# The Iosevka archive is ~254 MB for the four faces the CSS declares, so only those
# are kept. Dropping them under ui/static makes the SvelteKit build copy them into
# build/client/fonts/, where adapter-node serves them: no nginx alias needed.
ARG IOSEVKA_VERSION=34.6.3
ARG IOSEVKA_SHA256=6772ef93ee1e4b09f7ebb0165ad41b267ed88f392f92c917f1607e30335a3847
ARG TERMINUS_VERSION=4.49.3
ARG TERMINUS_SHA256=0ead921d98d99a4590ffe6cd66dc037fc0a2ceea1c735d866ba73fe058257577

RUN set -eux; \
    mkdir -p /src/ui/static/fonts/iosevka /src/ui/static/fonts/terminus; \
    curl -fsSL -o /tmp/iosevka.zip \
      "https://github.com/be5invis/Iosevka/releases/download/v${IOSEVKA_VERSION}/PkgWebFont-IosevkaTerm-${IOSEVKA_VERSION}.zip"; \
    echo "${IOSEVKA_SHA256}  /tmp/iosevka.zip" | sha256sum -c -; \
    unzip -j -o /tmp/iosevka.zip \
      'WOFF2/IosevkaTerm-Regular.woff2' 'WOFF2/IosevkaTerm-Medium.woff2' \
      'WOFF2/IosevkaTerm-Bold.woff2'    'WOFF2/IosevkaTerm-Italic.woff2' \
      -d /src/ui/static/fonts/iosevka; \
    curl -fsSL -o /tmp/iosevka-licence.md \
      "https://raw.githubusercontent.com/be5invis/Iosevka/v${IOSEVKA_VERSION}/LICENSE.md"; \
    cp /tmp/iosevka-licence.md /src/ui/static/fonts/iosevka/OFL.md; \
    curl -fsSL -o /tmp/terminus.zip \
      "https://files.ax86.net/terminus-ttf/files/${TERMINUS_VERSION}/terminus-ttf-${TERMINUS_VERSION}.zip"; \
    echo "${TERMINUS_SHA256}  /tmp/terminus.zip" | sha256sum -c -; \
    unzip -j -o /tmp/terminus.zip "terminus-ttf-${TERMINUS_VERSION}/*" -d /tmp/terminus; \
    cp /tmp/terminus/COPYING /src/ui/static/fonts/terminus/OFL.txt; \
    for pair in \
        "TerminusTTF-${TERMINUS_VERSION}.ttf:TerminusTTF" \
        "TerminusTTF-Bold-${TERMINUS_VERSION}.ttf:TerminusTTF-Bold" \
        "TerminusTTF-Italic-${TERMINUS_VERSION}.ttf:TerminusTTF-Italic" \
        "TerminusTTF-Bold-Italic-${TERMINUS_VERSION}.ttf:TerminusTTF-Bold-Italic"; do \
      cp "/tmp/terminus/${pair%%:*}" "/tmp/${pair##*:}.ttf"; \
      woff2_compress "/tmp/${pair##*:}.ttf"; \
      cp "/tmp/${pair##*:}.woff2" /src/ui/static/fonts/terminus/; \
    done; \
    rm -rf /tmp/iosevka.zip /tmp/terminus.zip /tmp/terminus

# The front end. `site/` is pijul-site, the pijul.org marketing website, and is not
# part of the Nest, so only `ui` is built.
RUN wasm-pack build identicon --release --target web    --out-dir pkg \
    && wasm-pack build identicon --release --target nodejs --out-dir pkg-node \
    && pnpm install --frozen-lockfile \
    && pnpm -F ui build

# The migrations hardcode GRANT ... TO pijul in 59 places across 24 files, which is
# why upstream's NixOS module runs `createuser pijul` first. Cloudron's postgresql
# addon role is NOSUPERUSER NOCREATEROLE, so that role cannot be created and the
# very first migration dies with `role "pijul" does not exist`. CURRENT_USER is a
# valid grantee and the grants become no-ops, since the migrating role already owns
# every table it just created. A pattern rather than a patch, so it survives
# upstream adding more of them, which it does regularly.
RUN grep -rlZ 'TO pijul' migrations | xargs -0 -r sed -i 's/\bTO pijul\b/TO CURRENT_USER/g' \
    && test "$(grep -rho 'TO pijul' migrations | wc -l)" = "0"

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: runtime.
# The base satisfies the nest binary with no added packages: ldd against a bare
# cloudron/base resolves libsodium, libssl, libcrypto, libgcc, libm and libc, and
# nothing else. diesel-cli needs libpq, which the base already carries.
# ─────────────────────────────────────────────────────────────────────────────
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

RUN mkdir -p /app/code /app/data
WORKDIR /app/code

COPY --from=build /src/target/release/nest       /app/code/bin/nest
COPY --from=build /src/target/release/nest-rank  /app/code/bin/nest-rank
COPY --from=build /opt/cargo/bin/diesel          /app/code/bin/diesel
COPY --from=build /src/ui/build                  /app/code/ui
COPY --from=build /src/migrations                /app/code/migrations
COPY --from=build /src/.upstream-change          /app/code/.upstream-change
COPY --from=build /src/COPYING                   /app/code/UPSTREAM-LICENCE

# After the binaries, so the wrapper scripts land alongside them in the same dir.
COPY bin/ /app/code/bin/
COPY start.sh /app/code/start.sh
COPY nginx.conf /app/code/nginx.conf
COPY supervisor/nest.conf /etc/supervisor/conf.d/nest.conf
COPY supervisor/supervisord.conf /app/code/supervisord.conf

RUN chmod +x /app/code/start.sh /app/code/bin/*

# CMD, never ENTRYPOINT: ENTRYPOINT breaks Cloudron's debug mode.
CMD [ "/app/code/start.sh" ]
