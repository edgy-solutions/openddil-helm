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


def keys_of(lasts):
    """{key: last_offset} -> key_lasts, every key last seen 5 s ago."""
    return {k: (v, NOW - 5_000) for k, v in lasts.items()}


def read(position=None, start=0, high=1000, head=NOW - 5_000, failed=None, subs=True,
         key_ms=None, topic="t"):
    """One key, `K`, whose own last record is high - 1."""
    r = chp.NodeRead(failed=list(failed or []))
    if subs:
        r.subs = [("Svc", "h", "b", topic)]
        kl = {"K": (high - 1, key_ms or head)} if head is not None else {}
        r.parts[("b", topic)] = {0: (start, high, head, kl, 0)}
    if position is not None:
        r.positions[("Svc", "h", topic, 0, "K")] = (position, NOW - 1000)
    return r


def multi(lasts, positions, high, errors=None):
    """Several keys on one partition; positions: {key: offset}."""
    r = chp.NodeRead()
    r.subs = [("Svc", "h", "b", "t")]
    r.parts[("b", "t")] = {0: (0, high, NOW - 5_000, keys_of(lasts), 0)}
    for k, o in positions.items():
        r.positions[("Svc", "h", "t", 0, k)] = (o, NOW - 7_000)
    r.key_errors.update(errors or {})
    return r


def states(node_read):
    return [x["state"] for x in chp.evaluate_node("n", node_read, TOL, NOW)]


class Parsing(unittest.TestCase):
    def test_describe_takes_high_not_start(self):
        self.assertEqual(chp.parse_describe(DESCRIBE), [(0, 75917, 214177)])

    def test_consume_keys_and_head_time(self):
        keys, head = chp.parse_consume(CONSUME)
        self.assertEqual(list(keys), ["dis:1:1:1005", "dis:1:1:1004", "dis:1:1:1003"])
        self.assertEqual(keys["dis:1:1:1005"], (1922470, 1793677338894))
        self.assertEqual(head, 1793677338894)

    def test_consume_reads_every_key_and_rejects_quote(self):
        # More than three keys: all returned, each with its own newest record.
        text = CONSUME + "0 1922471 1793677338900 dis:1:1:1005\n" \
            "0 1922472 1793677338901 bad'key\n0 1922473 1793677338902 dis:9\n"
        keys, head = chp.parse_consume(text)
        self.assertNotIn("bad'key", keys)
        self.assertEqual(list(keys), ["dis:9", "dis:1:1:1005", "dis:1:1:1004",
                                      "dis:1:1:1003"])
        self.assertEqual(keys["dis:1:1:1005"], (1922471, 1793677338900))
        self.assertEqual(keys["dis:1:1:1003"], (1922468, 1793677338800))
        self.assertEqual(keys.skipped, 1)
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
        out = chp.compare_passes(first, second, TOL, NOW)
        self.assertEqual([r["state"] for r in out], ["BEHIND"])

    def test_moved_position_keeps_ok(self):
        first = chp.evaluate_node("n", read(position=1050, high=1000), TOL, NOW)
        second = chp.evaluate_node("n", read(position=1100, high=1000 + TOL + 1), TOL, NOW)
        self.assertEqual([r["state"] for r in chp.compare_passes(first, second, TOL, NOW)],
                         ["OK"])


# These six are real readings from a live journal read: one handler, one
# partition, one moment (partition high 8182622).
SIX_POSITIONS = {
    "dis:5:1:1003": 8182620, "dis:5:1:1002": 8182624, "dis:2:1:1001": 8182627,
    "dis:2:1:1000": 8154211, "dis:2:1:1010": 8154226, "dis:2:1:1002": 8154257}
# Each key's own newest record in the window, near the head, distinct.
SIX_LASTS = {
    "dis:5:1:1003": 8182600, "dis:5:1:1002": 8182605, "dis:2:1:1001": 8182610,
    "dis:2:1:1000": 8182615, "dis:2:1:1010": 8182618, "dis:2:1:1002": 8182621}


class PerKey(unittest.TestCase):
    def test_half_the_keys_hours_behind_fails(self):
        # The case a maximum across keys passed: the newest key sat at the head.
        rows = chp.evaluate_node("n", multi(SIX_LASTS, SIX_POSITIONS, 8182622), TOL, NOW)
        self.assertEqual(len(rows), 1)
        r = rows[0]
        self.assertEqual(r["state"], "BEHIND")
        self.assertEqual(r["keys_behind"], 3)
        self.assertEqual(r["keys_read"], 6)
        self.assertEqual(r["key"], "dis:2:1:1000")
        self.assertEqual(sorted(r["behind_keys"]),
                         ["dis:2:1:1000", "dis:2:1:1002", "dis:2:1:1010"])
        self.assertEqual(r["behind_keys"][0], "dis:2:1:1000")
        self.assertFalse(chp.passes(rows))

    def test_quiet_key_is_measured_against_its_own_last(self):
        lasts = {"a": 999, "b": 998, "c": 997, "quiet": 499}
        pos = {"a": 999, "b": 998, "c": 997, "quiet": 499}
        rows = chp.evaluate_node("n", multi(lasts, pos, 1000), TOL, NOW)
        self.assertEqual([r["state"] for r in rows], ["OK"])
        self.assertEqual(rows[0]["keys_behind"], 0)

    def test_position_beyond_high_is_behind_zero(self):
        rows = chp.evaluate_node("n", multi({"a": 999}, {"a": 5000}, 1000), TOL, NOW)
        self.assertEqual(rows[0]["state"], "OK")
        self.assertEqual(rows[0]["behind"], 0)

    def test_key_verdict(self):
        old, young = NOW - 3_601_000, NOW - 60_000
        self.assertEqual(chp.key_verdict(900, 900 + TOL, young, NOW, TOL), "OK")
        self.assertEqual(chp.key_verdict(900, 900 + TOL + 1, young, NOW, TOL), "BEHIND")
        self.assertEqual(chp.key_verdict(None, 900, old, NOW, TOL), "IDLE")
        self.assertEqual(chp.key_verdict(None, 900, young, NOW, TOL), "UNREAD")

    def test_partition_state_order(self):
        def st(*s, head=NOW - 60_000):
            return chp.partition_state([{"state": x} for x in s], 0, 10, head, NOW)
        self.assertEqual(st("OK", "UNREAD", "IDLE", "BEHIND"), "BEHIND")
        self.assertEqual(st("OK", "UNREAD", "IDLE"), "UNREAD")
        self.assertEqual(st("IDLE", "OK", "IDLE"), "OK")
        self.assertEqual(st("IDLE", "IDLE"), "IDLE")
        self.assertEqual(st(), "UNREAD")
        self.assertEqual(st(head=NOW - 3_601_000), "IDLE")
        self.assertEqual(chp.partition_state([], 5, 5, None, NOW), "EMPTY")
        self.assertEqual(chp.partition_state([{"state": "OK"}], 0, 10, None, NOW, True),
                         "UNREAD")

    def test_compare_passes_per_key(self):
        lasts1 = {"a": 1000, "b": 1000, "c": 1000}
        pos1 = {"a": 1000, "b": 1100, "c": 1000}  # b ahead of its last
        lasts2 = {"a": 1000 + TOL + 1, "b": 1000 + TOL + 1, "c": 1000 + TOL + 1}
        pos2 = {"a": 1000 + TOL + 1, "b": 1100, "c": 1000 + TOL + 1}  # b unmoved
        first = chp.evaluate_node("n", multi(lasts1, pos1, 1001), TOL, NOW)
        second = chp.evaluate_node("n", multi(lasts2, pos2, 1001 + TOL + 1), TOL, NOW)
        self.assertEqual([r["state"] for r in second], ["OK"])
        out = chp.compare_passes(first, second, TOL, NOW)
        self.assertEqual([r["state"] for r in out], ["BEHIND"])
        self.assertEqual(out[0]["behind_keys"], ["b"])
        self.assertEqual(out[0]["key"], "b")

    def test_compare_passes_ignores_key_on_one_pass_only(self):
        first = chp.evaluate_node("n", multi({"a": 1000}, {"a": 1000}, 1001), TOL, NOW)
        second = chp.evaluate_node(
            "n", multi({"a": 1000 + TOL + 50, "new": 1000 + TOL + 50},
                       {"a": 1000 + TOL + 50, "new": 1100}, 1001 + TOL + 50), TOL, NOW)
        out = chp.compare_passes(first, second, TOL, NOW)
        self.assertEqual([r["state"] for r in out], ["OK"])

    def test_job_error_is_unread_and_keeps_behind_visible(self):
        text = "\n".join([
            json.dumps({"service": "Svc", "handler": "h", "key": "bad", "topic": "t",
                        "error": "HTTPError"}),
            json.dumps({"service": "Svc", "handler": "h", "key": "slow", "topic": "t",
                        "partition": 0, "offset": 100, "timestamp": NOW - 9_000}),
            "not json"])
        r = chp.NodeRead()
        r.subs = [("Svc", "h", "b", "t")]
        r.parts[("b", "t")] = {0: (0, 1000, NOW - 5_000,
                                   keys_of({"bad": 999, "slow": 998}), 0)}
        chp.apply_job_results(r, text)
        self.assertFalse(r.failed)
        rows = chp.evaluate_node("n", r, TOL, NOW)
        self.assertEqual(rows[0]["state"], "BEHIND")
        self.assertEqual(rows[0]["keys_unread"], 1)
        kr = {k["key"]: k for k in rows[0]["key_rows"]}
        self.assertEqual(kr["bad"]["state"], "UNREAD")
        self.assertEqual(kr["bad"]["note"], "HTTPError")
        self.assertFalse(chp.passes(rows))

    def test_journal_partition_mismatch_is_no_reading(self):
        text = json.dumps({"service": "Svc", "handler": "h", "key": "a", "topic": "t",
                           "partition": 3, "offset": 999, "timestamp": NOW})
        r = multi({"a": 999}, {}, 1000)
        chp.apply_job_results(r, text)
        self.assertEqual(states(r), ["UNREAD"])


class EventTopicTests(unittest.TestCase):
    def one(self, topic, **kw):
        return chp.evaluate_node("n", read(topic=topic, **kw), TOL, NOW)

    def test_effector_events_six_behind_is_behind(self):
        rows = self.one("effector-events", position=994, high=1001)
        self.assertEqual(rows[0]["state"], "BEHIND")

    def test_cm_events_one_behind_is_behind(self):
        rows = self.one("cm-events", position=999, high=1001)
        self.assertEqual(rows[0]["state"], "BEHIND")

    def test_snapshot_topic_keeps_tolerance(self):
        rows = self.one("raw-sensor-stream", position=994, high=1001)
        self.assertEqual(rows[0]["state"], "OK")
        rows = self.one("raw-sensor-stream", position=1000 - TOL - 1, high=1001)
        self.assertEqual(rows[0]["state"], "BEHIND")

    def test_event_topic_caught_up_is_ok(self):
        rows = self.one("effector-events", position=1000, high=1001)
        self.assertEqual(rows[0]["state"], "OK")

    def test_event_topic_idle_passes_and_is_named(self):
        old = NOW - 2 * 3600 * 1000
        rows = self.one("effector-events", high=1001, head=old, key_ms=old)
        self.assertEqual(rows[0]["state"], "IDLE")
        self.assertTrue(chp.passes(rows))
        idle = chp.event_idle_keys(rows)
        self.assertEqual([(i["topic"], i["key"]) for i in idle],
                         [("effector-events", "K")])

    def test_snapshot_topic_idle_not_listed(self):
        old = NOW - 2 * 3600 * 1000
        rows = self.one("raw-sensor-stream", high=1001, head=old, key_ms=old)
        self.assertEqual(rows[0]["state"], "IDLE")
        self.assertEqual(chp.event_idle_keys(rows), [])


if __name__ == "__main__":
    unittest.main()
