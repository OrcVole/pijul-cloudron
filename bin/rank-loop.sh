#!/bin/bash
set -eu -o pipefail

# PageRank over the repository graph.
#
# Upstream runs this from a systemd timer: OnBootSec=5min, then OnUnitActiveSec=6h.
# Reproduced as a sleeping loop under supervisor rather than a cron entry, so its
# output goes to the app log with everything else and there is no second scheduler
# in the container to reason about.
#
# A failure here is not fatal to the app: ranking affects ordering, not correctness,
# so the loop reports and carries on rather than taking the process down and making
# supervisor restart-storm.

export DATABASE_URL="${CLOUDRON_POSTGRESQL_URL}"

readonly FIRST_DELAY=300      # 5 minutes, matching OnBootSec
readonly INTERVAL=21600       # 6 hours, matching OnUnitActiveSec

sleep "${FIRST_DELAY}"

while true; do
    echo "==> nest-rank starting"
    if /app/code/bin/nest-rank; then
        echo "==> nest-rank finished"
    else
        echo "==> nest-rank failed with status $?, continuing; ranking affects ordering only" >&2
    fi
    sleep "${INTERVAL}"
done
