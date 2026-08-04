import json, sys, time, base64, urllib.request
import websocket  # provided by python3-websocket-client if available; fallback below

CDP_HOST = "127.0.0.1:9333"

def get_ws_url():
    req = urllib.request.Request(
        f"http://{CDP_HOST}/json/new?http://127.0.0.1:18081/", method="PUT"
    )
    with urllib.request.urlopen(req) as r:
        info = json.loads(r.read())
    return info["webSocketDebuggerUrl"], info["id"]

def main():
    ws_url, target_id = get_ws_url()
    ws = websocket.create_connection(ws_url, timeout=15)
    msg_id = 0

    def send(method, params=None):
        nonlocal msg_id
        msg_id += 1
        ws.send(json.dumps({"id": msg_id, "method": method, "params": params or {}}))
        return msg_id

    def recv_until(match_id, deadline):
        while time.time() < deadline:
            ws.settimeout(max(0.5, deadline - time.time()))
            try:
                raw = ws.recv()
            except Exception:
                return None
            data = json.loads(raw)
            if data.get("id") == match_id:
                return data
        return None

    send("Page.enable")
    send("Runtime.enable")
    nav_id = send("Page.navigate", {"url": "http://127.0.0.1:18081/"})
    recv_until(nav_id, time.time() + 10)

    # Hard wait, not a load-event wait: SSE / long-lived connections can make
    # "wait for load" hang even though the page has fully rendered.
    time.sleep(4)

    shot_id = send("Page.captureScreenshot", {"format": "png"})
    result = recv_until(shot_id, time.time() + 15)
    if not result or "result" not in result:
        print("NO SCREENSHOT RESULT", result, file=sys.stderr)
        sys.exit(1)
    png = base64.b64decode(result["result"]["data"])
    with open(sys.argv[1], "wb") as f:
        f.write(png)
    print(f"wrote {len(png)} bytes")

if __name__ == "__main__":
    main()
