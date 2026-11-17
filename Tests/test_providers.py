import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import providers as p


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.cfg = dict(provider="dnspod", domain="example.com", subdomain="mac", record_id="123")
        self.record = dict(RecordId=123, Name="mac", Type="A", Status="ENABLE",
                           Value="192.168.1.20", TTL=600, Line="默认")

    def request(self, operation="sync", cfg=None):
        return dict(config=cfg or self.cfg, operation=operation, address="192.168.1.21")

    @patch("providers.call")
    def test_dnspod_update_preserves_attributes_and_reads_back(self, call):
        updated = dict(self.record, Value="192.168.1.21")
        call.side_effect = [{"RecordList": [self.record]}, {}, {"RecordList": [updated]}]
        self.assertTrue(p.execute(self.request())["success"])
        args = call.call_args_list[1].args
        self.assertEqual(args[2], "ModifyRecord")
        self.assertEqual(args[3]["TTL"], 600)
        self.assertEqual(args[3]["RecordLine"], "默认")

    @patch("providers.call")
    def test_noop(self, call):
        call.return_value = {"RecordList": [self.record]}
        request = self.request(); request["address"] = self.record["Value"]
        p.execute(request)
        self.assertEqual(call.call_count, 1)

    @patch("providers.call")
    def test_probe_is_readonly_and_ambiguity_is_error(self, call):
        call.return_value = {"RecordList": [self.record]}
        self.assertEqual(p.execute(self.request("probe"))["record_id"], "123")
        self.assertEqual(call.call_count, 1)
        call.return_value = {"RecordList": [self.record, dict(self.record, RecordId=456)]}
        with self.assertRaises(p.Failure):
            p.execute(self.request("probe", dict(self.cfg, record_id="")))

    @patch("providers.call")
    def test_record_identity_checked(self, call):
        for changed in (dict(Name="other"), dict(Type="AAAA"), dict(Status="DISABLE"), dict(RecordId=9)):
            call.return_value = {"RecordList": [dict(self.record, **changed)]}
            with self.assertRaises(p.Failure): p.execute(self.request())

    @patch("providers.call")
    def test_failed_readback(self, call):
        call.side_effect = [{"RecordList": [self.record]}, {}, {"RecordList": [self.record]}]
        with self.assertRaises(p.Failure): p.execute(self.request())

    @patch("providers.call")
    def test_aliyun(self, call):
        record = dict(RecordId="a1", RR="mac", Type="A", Status="ENABLE", Value="192.168.1.20", TTL=120, Line="default")
        call.side_effect = [{"DomainRecords": {"Record": [record]}}, {},
                            {"DomainRecords": {"Record": [dict(record, Value="192.168.1.21")]}}]
        cfg = dict(self.cfg, provider="aliyun", record_id="a1")
        self.assertTrue(p.execute(self.request(cfg=cfg))["success"])
        self.assertEqual(call.call_args_list[1].args[2], "UpdateDomainRecord")
        self.assertEqual(call.call_args_list[1].args[3]["Line"], "default")

    @patch("providers.post")
    def test_signatures_wire_shapes(self, post):
        post.return_value = {"Response": {"RecordList": []}}
        p.tencent("DescribeRecordList", {"Domain": "example.com"}, {"access_id": "test", "secret": "secret"}, 1700000000)
        url, body, headers = post.call_args.args
        self.assertEqual(url, "https://dnspod.tencentcloudapi.com")
        self.assertIn("2023-11-14/dnspod/tc3_request", headers["Authorization"])
        self.assertEqual(headers["X-TC-Version"], "2021-03-23")
        self.assertEqual(p.percent("a b+c/~"), "a%20b%2Bc%2F~")

    def test_custom_executable_end_to_end(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "adapter with spaces"
            executable.write_text((Path(__file__).resolve().parents[1] / "Examples/mock-dns-adapter.py").read_text())
            executable.chmod(0o700)
            cfg = dict(self.cfg, provider="custom", record_id="", executable=str(executable))
            with patch.dict(os.environ, SCREENPEERS_MOCK_STATE=str(Path(directory) / "state.json")):
                result = p.execute(self.request("probe", cfg))
                self.assertEqual(result["record_id"], "mock-1")
                cfg["record_id"] = result["record_id"]
                result = p.execute(self.request(cfg=cfg))
                self.assertEqual(result["address"], "192.168.1.21")
                self.assertEqual(p.execute(self.request("probe", cfg))["address"], result["address"])

    def test_custom_wrong_record(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "adapter"
            script.write_text("#!/bin/sh\nprintf '%s' '{\"success\":true,\"record_id\":\"wrong\",\"address\":\"192.168.1.21\"}'\n")
            script.chmod(0o700)
            with self.assertRaises(p.Failure):
                p.execute(self.request(cfg=dict(self.cfg, provider="custom", executable=str(script))))


if __name__ == "__main__":
    unittest.main()
