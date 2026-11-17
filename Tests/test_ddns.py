import copy
import unittest
from subprocess import CompletedProcess
from unittest.mock import patch
from ddns import DDNSFailure, current_address, lan_address, reconcile

CFG = {"interface": "en1", "allowed_networks": ["192.168.10.0/24"],
       "dhcp_domain": "wifi.example", "subdomain": "mini", "ttl": 600}
LINK = "en1: flags=UP\n\tinet 192.168.10.60 netmask 0xffffe000\n\tstatus: active\n"
LEASE = "yiaddr = 192.168.10.60\ndomain_name (string): wifi.example\n"
RECORD = {"RecordId": 123, "Name": CFG["subdomain"], "Type": "A", "LineId": "0",
          "Status": "ENABLE", "Value": "192.168.10.59", "TTL": 600}


class FakeAPI:
    def __init__(self, records):
        self.records = copy.deepcopy(records)
        self.writes = []

    def __call__(self, action, **params):
        if action == "DescribeRecordList":
            return {"RecordList": copy.deepcopy(self.records)}
        self.writes.append((action, params))
        if action == "CreateRecord":
            self.records = [dict(RECORD, Value=params["Value"])]
            return {"RecordId": 123}
        self.records[0].update(Value=params["Value"], TTL=params["TTL"])
        return {}


class Tests(unittest.TestCase):
    def test_primary_interface_and_fallback_order(self):
        config = dict(CFG, interfaces={"en0": "wired.example", "en1": "wifi.example"})
        cases = [
            ("en1", {"en0", "en1"}, ["en1"]),
            ("en0", {"en0", "en1"}, ["en0"]),
            ("utun0", {"en0", "en1"}, ["en0"]),
            ("utun0", {"en1"}, ["en0", "en1"]),
            ("en0", {"en1"}, ["en0", "en1"]),
            ("en1", set(), ["en1", "en0"]),
        ]
        for primary, eligible, expected in cases:
            def read_address(interface_cfg):
                interface = interface_cfg["interface"]
                self.assertEqual(interface_cfg["dhcp_domain"], config["interfaces"][interface])
                if interface not in eligible:
                    raise DDNSFailure("Inactive or invalid lease")
                return interface

            with self.subTest(primary=primary, eligible=eligible), (
                patch("ddns.command", return_value=CompletedProcess(
                    [], 0, stdout=f"  PrimaryInterface : {primary}\n"))
            ), patch("ddns.interface_address", side_effect=read_address) as read:
                if eligible:
                    self.assertEqual(current_address(config), expected[-1])
                else:
                    with self.assertRaises(DDNSFailure):
                        current_address(config)
                self.assertEqual([call.args[0]["interface"] for call in read.call_args_list],
                                 expected)

    def test_physical_company_ip(self):
        self.assertEqual(lan_address(LINK, LEASE, CFG), "192.168.10.60")

    def test_wrong_or_inactive_network(self):
        variants = [(LINK.replace("en1:", "utun4:"), LEASE),
                    (LINK.replace("status: active", "status: inactive"), LEASE),
                    (LINK, LEASE.replace("wifi.example", "home")),
                    (LINK.replace("192.168.10.60", "192.168.1.20"), LEASE),
                    (LINK, LEASE.replace("192.168.10.60", "192.168.10.61"))]
        for link, lease in variants:
            with self.subTest(link=link, lease=lease), self.assertRaises(DDNSFailure):
                lan_address(link, lease, CFG)

    def test_changed_address_updates_explicit_value_and_pinned_id(self):
        api = FakeAPI([RECORD]); state = {"record_id": 123}; saved = []
        self.assertEqual(reconcile(api, CFG, state, "192.168.10.60", lambda s: saved.append(dict(s))), "updated")
        self.assertEqual(api.writes[0][1]["Value"], "192.168.10.60")
        self.assertEqual(api.writes[0][1]["RecordId"], 123)
        self.assertEqual(saved[-1]["last_ip"], "192.168.10.60")

    def test_unchanged_does_not_write_dns(self):
        api = FakeAPI([RECORD])
        self.assertEqual(reconcile(api, CFG, {"record_id": 123}, RECORD["Value"], lambda _: None), "unchanged")
        self.assertEqual(api.writes, [])

    def test_conflicts_refuse_writes(self):
        for records in [[RECORD, RECORD], [dict(RECORD, Type="CNAME")],
                        [dict(RECORD, Status="DISABLE")], [dict(RECORD, RecordId=456)],
                        [dict(RECORD, Name="www")], [dict(RECORD, LineId="10=1")], []]:
            api = FakeAPI(records)
            with self.subTest(records=records), self.assertRaises(DDNSFailure):
                reconcile(api, CFG, {"record_id": 123}, "192.168.10.60", lambda _: None)
            self.assertEqual(api.writes, [])

    def test_bootstrap_pins_before_verification(self):
        api = FakeAPI([]); saves = []; state = {}
        self.assertEqual(reconcile(api, CFG, state, "192.168.10.60", lambda s: saves.append(dict(s)), bootstrap=True), "created")
        self.assertEqual(saves[0], {"record_id": 123})
        self.assertEqual(state["last_ip"], "192.168.10.60")

    def test_never_adopts_unpinned_record(self):
        api = FakeAPI([RECORD])
        with self.assertRaises(DDNSFailure):
            reconcile(api, CFG, {}, "192.168.10.60", lambda _: None, bootstrap=True)
        self.assertEqual(api.writes, [])

    def test_dry_run_does_not_write_or_advance_state(self):
        api = FakeAPI([RECORD]); state = {"record_id": 123}; saves = []
        self.assertEqual(reconcile(api, CFG, state, "192.168.10.60", saves.append, dry_run=True), "would-update")
        self.assertEqual(api.writes, [])
        self.assertEqual(saves, [])
        self.assertEqual(state, {"record_id": 123})

    def test_failed_update_does_not_mark_success(self):
        api = FakeAPI([RECORD]); state = {"record_id": 123}; saves = []
        def failing(action, **params):
            if action == "ModifyRecord":
                raise DDNSFailure("API unavailable")
            return api(action, **params)
        with self.assertRaises(DDNSFailure):
            reconcile(failing, CFG, state, "192.168.10.60", saves.append)
        self.assertEqual(state, {"record_id": 123})
        self.assertEqual(saves, [])


if __name__ == "__main__":
    unittest.main()
