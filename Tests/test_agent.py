import unittest
import os
from unittest.mock import patch
from pathlib import Path
import agent
import ddns


class ObservationTests(unittest.TestCase):
    def test_legacy_helper_requires_explicit_job_label(self):
        with patch.dict(os.environ, {}, clear=True), patch("agent.run") as run:
            with self.assertRaises(ddns.DDNSFailure):
                agent.legacy_loaded()
            run.assert_not_called()

    def test_legacy_helper_checks_configured_job(self):
        with patch.dict(os.environ, SCREENPEERS_LEGACY_JOB_LABEL="com.example.ddns"), patch("agent.run") as run:
            run.return_value.returncode = 0
            self.assertTrue(agent.legacy_loaded())
            self.assertEqual(run.call_args.args[0][-1], f"gui/{os.getuid()}/com.example.ddns")

    def test_sources_deduplicate_and_ignore_outbound_listeners_and_other_ports(self):
        listing = '''Active Internet connections
Proto Recv-Q Send-Q Local Address Foreign Address (state)
tcp4 0 0 192.168.1.1.5900 192.168.1.2.40000 ESTABLISHED
tcp4 0 0 192.168.1.1.5900 192.168.1.2.40001 ESTABLISHED
tcp6 0 0 ::1.5900 ::ffff:192.168.1.2.40002 ESTABLISHED
tcp6 0 0 ::1.5900 fe80::123%en0.40003 ESTABLISHED
tcp4 0 0 192.168.1.1.40000 192.168.1.3.5900 ESTABLISHED
tcp4 0 0 *.5900 *.* LISTEN
tcp4 0 0 192.168.1.1.22 192.168.1.4.40000 ESTABLISHED
'''
        self.assertEqual(agent.parse_peers(listing), ["192.168.1.2", "fe80::123%en0"])

    def test_unreadable_is_not_zero(self):
        with self.assertRaises(ddns.DDNSFailure):
            agent.parse_peers("")
        self.assertEqual(agent.parse_peers("Local Address Foreign Address"), [])

    def test_addresses_independent_of_ddns_and_primary_order(self):
        listing = '''lo0: flags
    inet 127.0.0.1 netmask 0xff
en0: flags
    inet 192.168.1.2 netmask 0xff
en1: flags
    inet 192.168.2.2 netmask 0xff
'''
        result = agent.parse_interfaces(listing, {"en1": "Wi-Fi"}, "en1")
        self.assertEqual([row["interface"] for row in result], ["en1", "en0"])
        self.assertEqual(result[0]["name"], "Wi-Fi")
        self.assertTrue(result[0]["primary"])

    def test_old_scheduler_blocks_writes(self):
        with patch("agent.legacy_loaded", return_value=True), patch("agent.subprocess.run") as run:
            with self.assertRaises(ddns.DDNSFailure):
                agent.sync(Path("config.json"))
            run.assert_not_called()

    def test_failed_snapshot_retains_unknown(self):
        with patch("agent.run", side_effect=ddns.DDNSFailure("denied")):
            result = agent.snapshot(None)
        self.assertIsNone(result["peers"])
        self.assertIsNone(result["dns"])


if __name__ == "__main__":
    unittest.main()
