"""Per-tier scope on declared-idle-topics.yaml. No cluster needed."""
import pathlib
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
import check_tier_feed as ctf  # noqa: E402


def load_text(text):
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d) / "decl.yaml"
        p.write_text(text, encoding="utf-8")
        old = ctf.IDLE_DECL
        ctf.IDLE_DECL = p
        try:
            return ctf.load_idle_declarations()
        finally:
            ctf.IDLE_DECL = old


def doc(tiers_lines):
    return ("version: 1\ntopics:\n\n  t1:\n    status: declared\n"
            + tiers_lines + "    reason: x\n")


class Scope(unittest.TestCase):
    def test_unscoped_applies_anywhere(self):
        decl = {"t": {"status": "declared"}}
        self.assertIsNotNone(ctf.declaration_for(decl, "t", "edge-01"))

    def test_scoped_applies_at_listed_tier(self):
        decl = {"t": {"status": "declared", "tiers": ["edge-02"]}}
        self.assertIsNotNone(ctf.declaration_for(decl, "t", "edge-02"))

    def test_scoped_does_not_apply_elsewhere(self):
        decl = {"t": {"status": "declared", "tiers": ["edge-02"]}}
        self.assertIsNone(ctf.declaration_for(decl, "t", "edge-01"))

    def test_kind_excuses_every_region_not_edge(self):
        decl = {"t": {"status": "declared", "tiers": ["region"]}}
        for tier in ("region-east", "region-west", "region"):
            self.assertIsNotNone(ctf.declaration_for(decl, "t", tier), tier)
        self.assertIsNone(ctf.declaration_for(decl, "t", "edge-01"))
        self.assertIn("declared only for: region",
                      ctf.scope_note(decl, "t", "edge-01"))
        self.assertEqual(ctf.scope_note(decl, "t", "region-east"), "")

    def test_kind_does_not_match_prefix_without_dash(self):
        decl = {"t": {"status": "declared", "tiers": ["edge"]}}
        self.assertIsNone(ctf.declaration_for(decl, "t", "edgeless-01"))
        self.assertIsNotNone(ctf.declaration_for(decl, "t", "edge-01"))

    def test_kind_never_stale_with_no_region_deployed(self):
        out = self._run_main(
            {"t": {"status": "declared", "tiers": ["region"]}}, ["edge-01"])
        self.assertNotIn("STALE SCOPE", out)

    def test_exact_id_not_deployed_is_stale(self):
        out = self._run_main(
            {"t": {"status": "declared", "tiers": ["region-west"]}},
            ["edge-01"])
        self.assertIn("STALE SCOPE  t: tier region-west is not deployed", out)

    def _run_main(self, decl, tier_ids):
        import contextlib
        import io
        names = ("TIER_SUBSCRIPTIONS", "kubectl", "require_cluster", "tiers", "load_idle_declarations",
                 "broker_topics", "projector_mappings", "direct_ingest",
                 "stale_keyed_rows", "null_keyed_relayed",
                 "unentitled_detection", "watermark")
        saved = {k: getattr(ctf, k) for k in names}
        ctf.kubectl = lambda *a: "ctx"
        ctf.require_cluster = lambda c: None
        ctf.tiers = lambda ns: tier_ids
        ctf.load_idle_declarations = lambda: decl
        ctf.broker_topics = lambda ns, t: set()
        ctf.projector_mappings = lambda ns, t: []
        ctf.direct_ingest = lambda ns, t: True
        ctf.stale_keyed_rows = lambda *a: []
        ctf.null_keyed_relayed = lambda *a: []
        ctf.unentitled_detection = lambda *a: ([], [])
        ctf.watermark = lambda *a: 0
        ctf.TIER_SUBSCRIPTIONS = []
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                ctf.main()
        finally:
            for k, v in saved.items():
                setattr(ctf, k, v)
        return buf.getvalue()

    def test_loader_parses_flow_list(self):
        out = load_text(doc('    tiers: [edge-02, "region-east"]\n'))
        self.assertEqual(out["t1"]["tiers"], ["edge-02", "region-east"])

    def test_loader_refuses_bad_forms(self):
        for bad in ("    tiers: []\n",
                    "    tiers:\n      - edge-02\n",
                    "    tiers: edge-02\n",
                    "    tiers: [edge-02\n"):
            with self.subTest(bad=bad):
                with self.assertRaises(SystemExit) as cm:
                    load_text(doc(bad))
                self.assertEqual(cm.exception.code, 78)

    def test_real_file(self):
        out = ctf.load_idle_declarations()
        self.assertEqual(out["effector-events"]["status"], "declared")
        self.assertEqual(out["effector-events"]["tiers"], ["edge-02"])
        self.assertEqual(out["asset-element-telemetry"]["status"], "declared")
        self.assertEqual(out["asset-element-telemetry"]["tiers"],
                         ["region"])
        self.assertTrue(out["asset-element-telemetry"]["idle_unless_profiled"])
        scoped = {"effector-events", "asset-element-telemetry"}
        for k, v in out.items():
            if k not in scoped:
                self.assertNotIn("tiers", v, k)


if __name__ == "__main__":
    unittest.main()
