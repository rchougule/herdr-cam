"""Stand-in for the herdr API socket. Logs every request line to argv[2] and answers
ok, or with an error when the pane id contains "missing". Usage:
    python3 -I fake_socket.py <socket-path> <log-path>
"""

import json
import os
import socket
import sys

path, log = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    os.unlink(path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(8)

while True:
    conn, _ = srv.accept()
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(4096)
        if not chunk:
            break
        buf += chunk
    line = buf.decode().strip()
    with open(log, "a") as f:
        f.write(line + "\n")
    try:
        req = json.loads(line)
        pane = req.get("params", {}).get("pane_id", "")
        if "missing" in pane:
            resp = {"id": req["id"], "error": {"code": "pane_not_found", "message": pane}}
        else:
            resp = {"id": req["id"], "result": {"type": "ok"}}
    except ValueError:
        resp = {"id": "?", "error": {"code": "bad_json", "message": line}}
    conn.sendall((json.dumps(resp) + "\n").encode())
    conn.close()
