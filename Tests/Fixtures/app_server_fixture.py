#!/usr/bin/env python3
"""Local JSON-RPC fixture. It never opens a network connection."""

import json
import os
from pathlib import Path
import sys
import threading
import time


ROOT = Path(os.environ["CODEX_BUDDY_FIXTURE_ROOT"])
MODE = os.environ.get("CODEX_BUDDY_FIXTURE_MODE", "healthy")
EVENTS = ROOT / "events.jsonl"
OUTPUT_LOCK = threading.Lock()
EVENT_LOCK = threading.Lock()


def record(event, **fields):
    with EVENT_LOCK:
        with EVENTS.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"event": event, **fields}) + "\n")


def emit(value):
    with OUTPUT_LOCK:
        sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def idle_notifications():
    # The test captures its RSS baseline before creating this marker.
    trigger = ROOT / "start-flood"
    while not trigger.exists():
        time.sleep(0.01)
    payload = "x" * 8192
    for index in range(8192):
        emit({"method": "fixture/idleNotification", "params": {"sequence": index, "payload": payload}})
    record("idleFloodFinished", payloadBytes=8192 * 8192)


record("spawn", pid=os.getpid(), mode=MODE)
reads = 0
for raw_line in sys.stdin:
    try:
        request = json.loads(raw_line)
    except ValueError:
        continue
    method = request.get("method")
    request_id = request.get("id")
    record("request", method=method, id=request_id)

    if method == "initialize":
        if MODE == "eof-initialize":
            sys.exit(0)
        if MODE == "hang-initialize":
            continue
        if MODE == "delayed-initialize":
            time.sleep(0.10)
        # An unsolicited notification and unrelated response must not consume
        # the pending initialize response or become a future cached result.
        emit({"method": "fixture/starting", "params": {"ready": False}})
        emit({"id": -999, "result": {"unrelated": True}})
        emit({"id": request_id, "result": {"userAgent": "local-fixture"}})
    elif method == "account/rateLimits/read":
        reads += 1
        if MODE == "eof-read":
            sys.exit(0)
        if MODE == "hang-read":
            continue
        if MODE == "delayed-read":
            time.sleep(0.20)
        if MODE == "controlled-read-error":
            # Keep the first read in flight long enough for concurrent callers
            # to join; the local control file can later permit real success.
            time.sleep(0.20)
            control = ROOT / "control.json"
            allowed = json.loads(control.read_text()).get("success", False) if control.exists() else False
            if not allowed:
                emit({"id": request_id, "error": {"code": -32001, "message": "local fixture authentication failure"}})
                continue
        if MODE == "noisy-stderr":
            sys.stderr.write("x" * (256 * 1024))
            sys.stderr.flush()
        emit({"method": "fixture/progress", "params": {"read": reads}})
        emit({"id": request_id, "result": {"rateLimits": {"primary": {"usedPercent": 10 + reads, "windowDurationMins": 300}}}})
        if MODE == "idle-notifications" and reads == 1:
            threading.Thread(target=idle_notifications, daemon=True).start()
