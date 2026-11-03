"""Offline self-test for check_handler_position.py.

No subprocess, no cluster. The fixtures below are the real text shapes from a
live `rpk topic describe -p`, a live `rpk topic consume -f '%p %o %d %k\\n'`
and a live Restate journal read (payload omitted).
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_handler_position as chp  # noqa: E402

# Live `rpk topic describe <topic> -p` output.
DESCRIBE = """\
PARTITION  LEADER  EPOCH  REPLICAS  LOG-START-OFFSET  HIGH-WATERMARK
0          0       1      [0]       75917             214177
"""

# Live `rpk topic consume -f '%p %o %d %k\n'` output (%d is epoch ms).
CONSUME = """\
0 1922468 1793677338800 dis:1:1:1003
0 1922469 1793677338850 dis:1:1:1004
0 1922470 1793677338894 dis:1:1:1005
"""

# Live journal Input entry, payload omitted.
ENTRY = json.dumps({"Command": {"Input": {"headers": [
    {"name": "kafka.offset", "value": "1922470"},
    {"name": "kafka.topic", "value": "raw-sensor-stream"},
    {"name": "kafka.partition", "value": "0"},
    {"name": "kafka.timestamp", "value": "1793677338894"},
    {"name": "restate.subscription.id", "value": "sub_17c5p7CPI6xWSUaWC8DKLYZ"},
    {"name": "kafka.key", "value": "ZGlzOjE6MToxMDA1"}],
    "payload": "...", "name": "..."}}})

NOW = 1793677338894 + 10_000
TOL = 100


def read(position=None, start=0, high=1000, head=NOW - 5_000, failed=None, subs=True):
    r = chp.NodeRead(failed=list(failed or []))
    if subs:
        r.subs = [("Svc", "h", "b", "t")]
        r.parts[("b", "t")] = {0: (start, high, head)}
    if position is not None:
        r.positions[("Svc", "h", "t", 0)] = (position, NOW - 1000)
    return r


def states(node_read):
    return [x["state"] for x in chp.evaluate_node("n", node_read, TOL, NOW)]


class Parsing(unittest.TestCase):
    def test_describe_takes_high_not_start(self):
        self.assertEqual(chp.parse_describe(DESCRIBE), [(0, 75917, 214177)])

    def test_consume_keys_and_head_time(self):
        keys, head = chp.parse_consume(CONSUME)
        self.assertEqual(keys, ["dis:1:1:1005", "dis:1:1:1004", "dis:1:1:1003"])
        self.assertEqual(head, 1793677338894)

    def test_consume_limits_distinct_and_rejects_quote(self):
        text = CONSUME + "0 1922471 1793677338900 dis:1:1:1005\n" \
            "0 1922472 1793677338901 bad'key\n0 1922473 1793677338902 dis:9\n"
        keys, head = chp.parse_consume(text)
        self.assertNotIn("bad'key", keys)
        self.assertEqual(keys, ["dis:9", "dis:1:1:1005", "dis:1:1:1004"])
        self.assertEqual(head, 1793677338902)

    def test_journal_real_entry(self):
        self.assertEqual(chp.parse_journal(ENTRY), {
            "offset": 1922470, "partition": 0, "timestamp": 1793677338894,
            "topic": "raw-sensor-stream"})

    def test_journal_without_offset_is_none(self):
        e = json.loads(ENTRY)
        e["Command"]["Input"]["headers"] = [
            h for h in e["Command"]["Input"]["headers"] if h["name"] != "kafka.offset"]
        self.assertIsNone(chp.parse_journal(json.dumps(e)))
        self.assertIsNone(chp.parse_journal("not json"))


class Verdicts(unittest.TestCase):
    def test_tolerance_boundary(self):
        self.assertEqual(states(read(position=999 - TOL)), ["OK"])
        self.assertEqual(states(read(position=999 - TOL - 1)), ["BEHIND"])

    def test_position_ahead_of_last_is_ok(self):
        self.assertEqual(states(read(position=5000)), ["OK"])

    def test_no_reading_young_head_unread_old_head_idle(self):
        self.assertEqual(states(read(head=NOW - 60_000)), ["UNREAD"])
        self.assertEqual(states(read(head=NOW - 3_601_000)), ["IDLE"])

    def test_no_lines_is_unread(self):
        self.assertEqual(states(read(head=None)), ["UNREAD"])

    def test_empty_partition_passes(self):
        self.assertEqual(states(read(start=500, high=500, head=None)), ["EMPTY"])

    def test_failed_node_read_fails_run(self):
        rows = chp.evaluate_node("n", read(position=999, failed=["positions unreadable"]),
                                 TOL, NOW)
        self.assertFalse(chp.passes(rows))
        self.assertTrue(all(r["state"] == "UNREAD" for r in rows))

    def test_zero_subscriptions_fails(self):
        rows = chp.evaluate_node("n", read(subs=False), TOL, NOW)
        self.assertEqual([r["state"] for r in rows], ["UNREAD"])
        self.assertFalse(chp.passes(rows))

    def test_zero_tiers_fails(self):
        self.assertIsNone(chp.nodes_for([]))
        self.assertEqual(chp.nodes_for(["a"]), ["hub", "a"])

    def test_nothing_read_is_not_a_pass(self):
        self.assertFalse(chp.passes([]))

    def test_unmoved_position_fails(self):
        first = chp.evaluate_node("n", read(position=1050, high=1000), TOL, NOW)
        second = chp.evaluate_node("n", read(position=1050, high=1000 + TOL + 1), TOL, NOW)
        self.assertEqual([r["state"] for r in second], ["OK"])
        out = chp.compare_passes(first, second, TOL)
        self.assertEqual([r["state"] for r in out], ["BEHIND"])

    def test_moved_position_keeps_ok(self):
        first = chp.evaluate_node("n", read(position=1050, high=1000), TOL, NOW)
        second = chp.evaluate_node("n", read(position=1100, high=1000 + TOL + 1), TOL, NOW)
        self.assertEqual([r["state"] for r in chp.compare_passes(first, second, TOL)], ["OK"])


if __name__ == "__main__":
    unittest.main()
