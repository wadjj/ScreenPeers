#!/usr/bin/env python3
"""Local protocol demo; no network requests or real DNS changes."""
import ipaddress
import json
import os
from pathlib import Path
import sys
import tempfile

request = json.load(sys.stdin)
assert request["version"] == 1
assert request["hostname"] == "mac.example.com"
assert request["operation"] in ("probe", "sync")
assert request.get("record_id") in ("", "mock-1")
state = Path(os.environ.get("SCREENPEERS_MOCK_STATE", str(Path(tempfile.gettempdir()) / "screenpeers-mock-dns.json")))
address = json.loads(state.read_text())["address"] if state.exists() else "192.168.1.20"
if request["operation"] == "sync":
    address = str(ipaddress.IPv4Address(request["address"]))
    state.write_text(json.dumps({"address": address}))
print(json.dumps({"success": True, "record_id": "mock-1", "address": address}))
