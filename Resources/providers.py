"""One-shot provider bridge. Requests and credentials arrive on stdin, never argv."""
import base64
import datetime
import hashlib
import hmac
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import uuid


class Failure(Exception):
    pass


def digest(key, value, algorithm=hashlib.sha256):
    return hmac.new(key, value.encode(), algorithm).digest()


def post(url, data, headers):
    try:
        request = urllib.request.Request(url, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read(2 * 1024 * 1024))
    except Exception:
        raise Failure("服务商连接失败，请检查网络和账户设置")


def tencent(action, params, credential, timestamp=None):
    stamp = int(time.time()) if timestamp is None else timestamp
    date = datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).strftime("%Y-%m-%d")
    host = "dnspod.tencentcloudapi.com"
    body = json.dumps(params, separators=(",", ":"), ensure_ascii=False).encode()
    canonical = "POST\n/\n\ncontent-type:application/json\nhost:" + host + "\n\ncontent-type;host\n" + hashlib.sha256(body).hexdigest()
    scope = date + "/dnspod/tc3_request"
    signed = "TC3-HMAC-SHA256\n" + str(stamp) + "\n" + scope + "\n" + hashlib.sha256(canonical.encode()).hexdigest()
    key = digest(("TC3" + credential["secret"]).encode(), date)
    key = digest(digest(key, "dnspod"), "tc3_request")
    authorization = "TC3-HMAC-SHA256 Credential=" + credential["access_id"] + "/" + scope + ", SignedHeaders=content-type;host, Signature=" + digest(key, signed).hex()
    value = post("https://" + host, body, {"Content-Type": "application/json",
                 "Authorization": authorization, "X-TC-Action": action,
                 "X-TC-Timestamp": str(stamp), "X-TC-Version": "2021-03-23"})["Response"]
    if "Error" in value:
        raise Failure("腾讯云：" + str(value["Error"].get("Code", "APIError")))
    return value


def percent(value):
    return urllib.parse.quote(str(value), safe="~")


def aliyun_signature(params, secret):
    canonical = "&".join(percent(k) + "=" + percent(v) for k, v in sorted(params.items()))
    return base64.b64encode(digest((secret + "&").encode(), "POST&%2F&" + percent(canonical), hashlib.sha1)).decode()


def aliyun(action, params, credential):
    query = dict(params, Action=action, Format="JSON", Version="2015-01-09",
                 AccessKeyId=credential["access_id"], SignatureMethod="HMAC-SHA1",
                 SignatureVersion="1.0", SignatureNonce=str(uuid.uuid4()),
                 Timestamp=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    query["Signature"] = aliyun_signature(query, credential["secret"])
    value = post("https://alidns.aliyuncs.com/", urllib.parse.urlencode(query).encode(),
                 {"Content-Type": "application/x-www-form-urlencoded"})
    if "Code" in value:
        raise Failure("阿里云：" + str(value["Code"]))
    return value


def call(cfg, credential, action, params):
    if cfg["provider"] == "aliyun":
        return aliyun(action, params, credential)
    if cfg.get("profile") and not credential:
        # Existing installs may retain their tccli account until a new key is saved.
        argv = [cfg.get("tccli", "/opt/homebrew/bin/tccli"), "dnspod", action,
                "--profile", cfg["profile"], "--output", "json"]
        for key, value in params.items():
            argv += ["--" + key, str(value)]
        try:
            result = subprocess.run(argv, capture_output=True, timeout=30)
            if result.returncode:
                raise Failure("腾讯云账户调用失败，请检查原有 tccli 配置")
            value = json.loads(result.stdout)
            return value.get("Response", value)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise Failure("无法读取原有腾讯云账户")
    if not credential.get("access_id") or not credential.get("secret"):
        raise Failure("请填写账户密钥")
    return tencent(action, params, credential)


def records(cfg, credential):
    result = []
    page = 1
    while True:
        if cfg["provider"] == "dnspod":
            value = call(cfg, credential, "DescribeRecordList",
                         {"Domain": cfg["domain"], "SubDomain": cfg["subdomain"], "Limit": 100, "Offset": (page - 1) * 100})
            batch = value.get("RecordList", [])
        else:
            value = call(cfg, credential, "DescribeDomainRecords",
                         {"DomainName": cfg["domain"], "RRKeyWord": cfg["subdomain"],
                          "SearchMode": "EXACT", "PageSize": 100, "PageNumber": page})
            batch = value.get("DomainRecords", {}).get("Record", [])
        result.extend(batch)
        if len(batch) < 100:
            break
        page += 1
        if page > 100:
            raise Failure("记录过多，请缩小配置范围")
    return result


def select(cfg, credential):
    choices = [r for r in records(cfg, credential)
               if r.get("Name", r.get("RR")) == cfg["subdomain"] and r.get("Type") == "A"
               and r.get("Status", "ENABLE").upper() in ("ENABLE", "ENABLED")]
    if cfg.get("record_id"):
        choices = [r for r in choices if str(r["RecordId"]) == str(cfg["record_id"])]
    if len(choices) != 1:
        raise Failure("请先建立一条启用的 A 记录；存在多条时填写记录 ID")
    return choices[0]


def custom(cfg, operation, address):
    path = cfg.get("executable", "")
    if not os.path.isabs(path) or not os.access(path, os.X_OK):
        raise Failure("请选择可执行的自定义适配器")
    request = {"version": 1, "operation": operation, "domain": cfg["domain"],
               "subdomain": cfg["subdomain"], "hostname": hostname(cfg),
               "record_id": cfg.get("record_id", ""), "address": address}
    # Files bound parent-process memory even if an adapter writes verbose output.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        try:
            completed = subprocess.run([path], input=json.dumps(request).encode(),
                                       stdout=output, stderr=errors, timeout=40)
            output.seek(0)
            raw = output.read(65537)
            if completed.returncode or len(raw) > 65536:
                raise Failure("自定义适配器执行失败")
            value = json.loads(raw)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise Failure("自定义适配器超时或输出无效")
    if value.get("success") is not True or not value.get("record_id"):
        raise Failure("自定义适配器未返回成功和记录 ID")
    if cfg.get("record_id") and str(value["record_id"]) != str(cfg["record_id"]):
        raise Failure("自定义适配器返回的记录 ID 不一致")
    ipaddress.IPv4Address(value["address"])
    if operation == "sync" and value["address"] != address:
        raise Failure("自定义适配器读回的地址不一致")
    return {"RecordId": str(value["record_id"]), "Value": value["address"]}


def hostname(cfg):
    return cfg["domain"] if cfg["subdomain"] == "@" else cfg["subdomain"] + "." + cfg["domain"]


def execute(request):
    cfg = request["config"]
    if cfg.get("provider") not in ("dnspod", "aliyun", "custom"):
        raise Failure("请选择 DNS 服务商")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", cfg.get("domain", "")) or not re.fullmatch(r"@|[A-Za-z0-9_.-]+", cfg.get("subdomain", "")):
        raise Failure("请填写域名和主机记录")
    operation = request.get("operation", "probe")
    if operation not in ("probe", "sync"):
        raise Failure("未知操作")
    address = request.get("address")
    if operation == "sync":
        ip = ipaddress.IPv4Address(address)
        if ip.is_unspecified or ip.is_loopback or ip.is_link_local or ip.is_multicast:
            raise Failure("当前没有可用的 IPv4 地址")
        if not cfg.get("record_id"):
            raise Failure("请先测试并保存配置")
    credential = request.get("credential", {})
    if cfg["provider"] == "custom":
        record = custom(cfg, operation, address)
    else:
        record = select(cfg, credential)
        if operation == "sync" and record["Value"] != address:
            if cfg["provider"] == "dnspod":
                call(cfg, credential, "ModifyRecord",
                     {"Domain": cfg["domain"], "RecordId": int(record["RecordId"]),
                      "SubDomain": cfg["subdomain"], "RecordType": "A",
                      "RecordLine": record["Line"], "Value": address, "TTL": int(record["TTL"])})
            else:
                call(cfg, credential, "UpdateDomainRecord",
                     {"RecordId": record["RecordId"], "RR": cfg["subdomain"], "Type": "A",
                      "Value": address, "TTL": record["TTL"], "Line": record.get("Line", "default")})
            record = select(cfg, credential)
            if record["Value"] != address:
                raise Failure("更新后读回地址不一致，将稍后重试")
    return {"success": True, "message": "已确认", "record_id": str(record["RecordId"]),
            "address": record["Value"], "verified": time.time()}


if __name__ == "__main__":
    try:
        result = execute(json.load(sys.stdin))
    except Failure as error:
        result = {"success": False, "message": str(error)}
    except Exception:
        result = {"success": False, "message": "配置或服务商响应无效，请检查设置"}
    print(json.dumps(result, ensure_ascii=False))
