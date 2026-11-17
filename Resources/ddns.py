#!/usr/bin/env python3
"""Publish the selected physical LAN address to one pinned DNSPod A record."""
import argparse
import fcntl
import ipaddress
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import re
import subprocess
import sys
import time


class DDNSFailure(Exception):
    pass


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        if default is not None:
            return default.copy()
        raise DDNSFailure("Required configuration is missing")
    except (ValueError, OSError):
        raise DDNSFailure("Cannot read configuration/state; refusing to reset record pin")


def write_json(path, data):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def command(args, timeout=10, input_text=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                              input=input_text)
    except subprocess.TimeoutExpired:
        raise DDNSFailure("Command timed out; retry on next scheduled run")
    except OSError:
        raise DDNSFailure("Required executable cannot be started")


def lan_address(interface_text, dhcp_text, cfg):
    interface = cfg["interface"]
    if not re.match(r"en\d+\Z", interface):
        raise DDNSFailure("Only an explicitly configured physical en interface is allowed")
    if not interface_text.startswith(interface + ":") or "status: active" not in interface_text:
        raise DDNSFailure("Configured LAN interface is inactive")
    addresses = re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)\b", interface_text)
    if len(addresses) != 1:
        raise DDNSFailure("Expected exactly one IPv4 address on configured LAN interface")
    try:
        addr = ipaddress.IPv4Address(addresses[0])
    except ValueError:
        raise DDNSFailure("Invalid LAN IPv4 address")
    if not any(addr in ipaddress.IPv4Network(net) for net in cfg["allowed_networks"]):
        raise DDNSFailure("LAN address is outside the configured trusted address ranges")
    if addr.is_loopback or addr.is_unspecified or addr.is_multicast or addr.is_link_local:
        raise DDNSFailure("Unsuitable LAN IPv4 address")
    domain = re.search(r"domain_name \(string\):\s*([^\s]+)", dhcp_text)
    lease_ip = re.search(r"^yiaddr = ([^\s]+)", dhcp_text, re.M)
    if not domain or domain[1].rstrip(".").lower() != cfg["dhcp_domain"].lower():
        raise DDNSFailure("DHCP domain does not match the configured trusted network")
    if not lease_ip or lease_ip[1] != str(addr):
        raise DDNSFailure("Current address does not match the DHCP lease")
    return str(addr)


def interface_address(cfg):
    interface = cfg["interface"]
    if not re.fullmatch(r"en\d+", interface):
        raise DDNSFailure("Invalid physical interface configuration")
    link = command(["/sbin/ifconfig", interface])
    lease = command(["/usr/sbin/ipconfig", "getpacket", interface])
    if link.returncode or lease.returncode:
        raise DDNSFailure("Cannot read active interface/DHCP lease")
    return lan_address(link.stdout, lease.stdout, cfg)


def current_address(cfg):
    interfaces = cfg.get("interfaces")
    if interfaces is None:
        return interface_address(cfg)

    candidates = list(interfaces)
    try:
        primary = command(["/usr/sbin/scutil"],
                          input_text="show State:/Network/Global/IPv4\n")
    except DDNSFailure:
        primary = None
    matches = []
    if primary is not None and primary.returncode == 0:
        matches = re.findall(r"^\s*PrimaryInterface\s*:\s*(en\d+)\s*$", primary.stdout, re.M)
    if len(matches) == 1 and matches[0] in interfaces:
        candidates.remove(matches[0])
        candidates.insert(0, matches[0])

    failures = []
    for interface in candidates:
        try:
            return interface_address(dict(cfg, interface=interface,
                                          dhcp_domain=interfaces[interface]))
        except DDNSFailure as error:
            failures.append(f"{interface}: {error}")
    raise DDNSFailure("No eligible LAN address (" + ", ".join(failures) + ")")


class DNSPod:
    def __init__(self, cfg):
        self.cfg = cfg

    def __call__(self, action, **params):
        cfg = self.cfg
        args = [cfg["tccli"], "dnspod", action, "--profile", cfg["profile"],
                "--output", "json", "--Domain", cfg["domain"],
                "--DomainId", str(cfg["domain_id"])]
        for key, value in params.items():
            args += ["--" + key, str(value)]
        result = command(args, timeout=40)
        try:
            payload = json.loads(result.stdout)
            payload = payload.get("Response", payload)
        except (ValueError, AttributeError):
            # CLI error text can contain request details. Keep it out of our logs.
            code = re.search(r"code:\s*([A-Za-z0-9_.]+)", result.stderr + result.stdout)
            raise DDNSFailure("DNSPod CLI failed" + (": " + code[1] if code else ""))
        if result.returncode or "Error" in payload:
            code = payload.get("Error", {}).get("Code", "UnknownError")
            code = re.sub(r"[^A-Za-z0-9_.]", "", str(code))[:100]
            raise DDNSFailure("DNSPod API failed: " + code)
        return payload


def select_record(api, cfg, pinned_id=None):
    result = api("DescribeRecordList", SubDomain=cfg["subdomain"],
                 ErrorOnEmpty="no", Limit=100)
    records = result.get("RecordList") or []
    total = result.get("RecordCountInfo", {}).get("TotalCount", len(records))
    if int(total) != len(records) or len(records) > 1:
        raise DDNSFailure("Multiple or incomplete target records; manual review required")
    if not records:
        if pinned_id:
            raise DDNSFailure("Pinned record was removed; refusing to recreate it automatically")
        return None
    record = records[0]
    if (record.get("Name", "").lower() != cfg["subdomain"].lower()
            or record.get("Type") != "A" or str(record.get("LineId")) != "0"
            or record.get("Status", "").upper() != "ENABLE"):
        raise DDNSFailure("Target must be a single enabled default-line A record")
    if pinned_id and int(record["RecordId"]) != int(pinned_id):
        raise DDNSFailure("Target record ID changed; manual review required")
    return record


def reconcile(api, cfg, state, address, save, bootstrap=False, dry_run=False):
    pinned_id = state.get("record_id")
    if not pinned_id and not bootstrap:
        raise DDNSFailure("No pinned record; run --bootstrap once after reviewing DNS")
    record = select_record(api, cfg, pinned_id)
    common = dict(SubDomain=cfg["subdomain"], RecordType="A", RecordLine="默认",
                  RecordLineId="0", Value=address, TTL=cfg["ttl"], Status="ENABLE")
    if record is None:
        if dry_run:
            return "would-create"
        created = api("CreateRecord", **common, Remark="ScreenPeers DDNS")
        state["record_id"] = int(created["RecordId"])
        save(state)  # Persist the new identity before any later verification can fail.
        result = "created"
    else:
        if not pinned_id:
            # Do not adopt an unrelated pre-existing record during initial setup.
            raise DDNSFailure("Target already exists without a local pin; manual review required")
        if record["Value"] == address and int(record["TTL"]) == cfg["ttl"]:
            if not dry_run:
                state.update(last_ip=address, last_verified=time.time())
                save(state)
            return "unchanged"
        if dry_run:
            return "would-update"
        api("ModifyRecord", RecordId=state["record_id"], **common)
        result = "updated"
    verified = select_record(api, cfg, state["record_id"])
    if verified["Value"] != address or int(verified["TTL"]) != cfg["ttl"]:
        raise DDNSFailure("DNSPod write read-back mismatch; retry next run")
    state.update(last_ip=address, last_verified=time.time())
    save(state)
    return result


def status_snapshot(cfg, runtime):
    state = read_json(runtime / "state.json", {})
    try:
        address = current_address(cfg)
    except DDNSFailure:
        address = None
    last_ip = state.get("last_ip")
    verified = state.get("last_verified", 0)
    recent = 0 <= time.time() - verified < cfg["verify_interval"] + 60
    sync = "unknown"
    if address and last_ip and address != last_ip:
        sync = "pending"
    elif address and address == last_ip and recent:
        sync = "synced"
    return {
        "hostname": cfg["subdomain"] + "." + cfg["domain"],
        "address": address,
        "publishedAddress": last_ip,
        "sync": sync,
        "manualResult": read_json(runtime / "manual-result.json", {}),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("config.json"))
    parser.add_argument("--bootstrap", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true", help="Bypass local 5-minute DNS verification cache")
    parser.add_argument("--status", action="store_true", help="Print local DDNS status as JSON")
    args = parser.parse_args()
    os.umask(0o077)
    cfg = read_json(args.config)
    runtime = Path(cfg["runtime_dir"])
    if args.status:
        print(json.dumps(status_snapshot(cfg, runtime)))
        return 0
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    handler = RotatingFileHandler(runtime / "ddns.log", maxBytes=524288, backupCount=2)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger = logging.getLogger("macmini-ddns")
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)
    lock = (runtime / "ddns.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    manual_id = None
    manual_success = False
    try:
        if not args.dry_run and not args.bootstrap:
            request = runtime / "manual-request"
            try:
                manual_id = request.read_text().strip()
                request.unlink()
            except FileNotFoundError:
                pass
        address = current_address(cfg)
        state_path = runtime / "state.json"
        state = read_json(state_path, {})
        if (not manual_id and not args.force and not args.bootstrap and not args.dry_run
                and state.get("record_id") and state.get("last_ip") == address
                and 0 <= time.time() - state.get("last_verified", 0) < cfg["verify_interval"]):
            return 0
        result = reconcile(DNSPod(cfg), cfg, state, address,
                           lambda data: write_json(state_path, data),
                           args.bootstrap, args.dry_run)
        message = "%s %s.%s -> %s" % (result, cfg["subdomain"], cfg["domain"], address)
        logger.info(message)
        print(message)
        manual_success = True
        return 0
    except DDNSFailure as error:
        logger.warning("%s", error)
        print(str(error), file=sys.stderr)
        return 1
    except Exception as error:
        logger.error("Unexpected %s; no raw request or credentials logged", type(error).__name__)
        print("Unexpected error; see local log for error type", file=sys.stderr)
        return 1
    finally:
        if manual_id:
            write_json(runtime / "manual-result.json", {"id": manual_id, "success": manual_success})
        lock.close()


if __name__ == "__main__":
    sys.exit(main())
