"""Read-only observations and guarded, one-shot DNS synchronization for ScreenPeers."""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import ddns


def run(args, input_text=None):
    return ddns.command(args, timeout=8, input_text=input_text)


def parse_peers(text):
    if "Local Address" not in text or "Foreign Address" not in text:
        raise ddns.DDNSFailure("Cannot read TCP connections")
    peers = set()
    for line in text.splitlines():
        cols = line.split()
        if len(cols) < 6 or not cols[0].startswith("tcp"):
            continue
        if not cols[3].endswith(".5900") or cols[5] != "ESTABLISHED":
            continue
        address = cols[4].rsplit(".", 1)[0]
        peers.add(address.removeprefix("::ffff:"))
    return sorted(peers)


def parse_interfaces(text, names, primary):
    result = []
    interface = None
    for line in text.splitlines():
        match = re.match(r"^(\w+):", line)
        if match:
            interface = match[1]
        match = re.match(r"\s+inet (\d+\.\d+\.\d+\.\d+) ", line)
        if match and interface and interface != "lo0":
            result.append({"id": interface + "/" + match[1], "interface": interface,
                           "name": names.get(interface, interface), "address": match[1],
                           "primary": interface == primary})
    return sorted(result, key=lambda item: (not item["primary"], item["interface"]))


def legacy_loaded():
    label = os.environ.get("SCREENPEERS_LEGACY_JOB_LABEL", "")
    if not label:
        raise ddns.DDNSFailure("Set SCREENPEERS_LEGACY_JOB_LABEL before using the legacy helper")
    return run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"]).returncode == 0


def snapshot(config):
    result = {"peers": None, "interfaces": [], "dns": None, "error": None}
    try:
        connections = run(["/usr/sbin/netstat", "-anW", "-p", "tcp"])
        if connections.returncode:
            raise ddns.DDNSFailure("Cannot read TCP connections")
        result["peers"] = parse_peers(connections.stdout)
    except ddns.DDNSFailure:
        result["error"] = "无法读取连接；请尝试重新打开 App"
    try:
        ports = run(["/usr/sbin/networksetup", "-listallhardwareports"]).stdout
        names = dict((device, name) for name, device in re.findall(
            r"Hardware Port: (.+)\nDevice: (\w+)", ports))
        network = run(["/usr/sbin/scutil"], "show State:/Network/Global/IPv4\n").stdout
        primary = re.search(r"PrimaryInterface\s*:\s*(\w+)", network)
        result["interfaces"] = parse_interfaces(run(["/sbin/ifconfig"]).stdout,
                                                 names, primary[1] if primary else None)
    except ddns.DDNSFailure:
        pass
    if config:
        try:
            cfg = ddns.read_json(config)
            state = ddns.read_json(Path(cfg["runtime_dir"]) / "state.json", {})
            result["dns"] = dict(ddns.status_snapshot(cfg, Path(cfg["runtime_dir"])),
                                 verified=state.get("last_verified"), legacyLoaded=legacy_loaded())
        except (ddns.DDNSFailure, KeyError, TypeError, ValueError):
            result["dns"] = {"hostname": "", "sync": "unknown", "legacyLoaded": False,
                             "error": "配置或记录状态不可用，请检查设置"}
    return result


def sync(config, force=False, dry_run=False):
    if not config:
        raise ddns.DDNSFailure("DDNS has not been configured")
    # The app never competes with the previous scheduled writer.
    if not dry_run and legacy_loaded():
        raise ddns.DDNSFailure("旧 DDNS 后台仍在运行；请先完成迁移")
    argv = [sys.executable, str(Path(__file__).with_name("ddns.py")), "--config", str(config)]
    if force:
        argv.append("--force")
    if dry_run:
        argv.append("--dry-run")
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=150)
    except subprocess.TimeoutExpired:
        raise ddns.DDNSFailure("更新超时；下一轮将重新核对")
    return {"success": result.returncode == 0,
            "message": (result.stdout if result.returncode == 0 else result.stderr).strip()[:600]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path)
    parser.add_argument("--sync", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        value = sync(args.config, args.force, args.dry_run) if args.sync else snapshot(args.config)
    except (ddns.DDNSFailure, OSError) as error:
        value = {"success": False, "message": str(error)}
    print(json.dumps(value, ensure_ascii=False))


if __name__ == "__main__":
    main()
