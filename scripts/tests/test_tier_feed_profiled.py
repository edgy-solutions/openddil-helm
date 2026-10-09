"""An edge's empty element topic is judged by its profiled assets. No cluster."""
import contextlib
import io
import pathlib
import sys
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
import check_tier_feed as ctf  # noqa: E402

TOPIC = "asset-element-telemetry"
CFG = """asset_profiles:
- faces:
  - cols: 8
    name: PRIMARY APERTURE
  layers:
  - name: RADAR UNIT
    prefix: TR
  match_subsystem: ASSET_SUBSYSTEM_SENSOR
  matches_platform_variants:
  - MRAD_Sensor
  - MRAD_Radar
  name: mrad
- layers:
  - cols: 2
    name: POWER MODULE
  matches_platform_variants:
  - MRAD_Interceptor
  name: mrad_interceptor
degraded_health_states:
- DEGRADED
element_publish_tier: %s
output_topic: asset-element-telemetry
"""
SENSOR = "ASSET_SUBSYSTEM_SENSOR"

PATCHED = (
    "kubectl", "require_cluster", "tiers", "load_idle_declarations", "broker_topics",
    "projector_mappings", "direct_ingest", "stale_keyed_rows",
    "null_keyed_relayed", "unentitled_detection", "watermark",
    "read_sim_config", "read_edge_assets", "TIER_SUBSCRIPTIONS")


def run_main(cfg, rows, tier="edge-01"):
    """Run main() for one tier with the topic fed and empty. -> (rc, out)."""
    decl = {TOPIC: {"status": "declared", "tiers": ["region"],
                    "idle_unless_profiled": True}}
    saved = {k: getattr(ctf, k, None) for k in PATCHED}
    ctf.kubectl = lambda *a: "ctx"
    ctf.require_cluster = lambda c: None
    ctf.tiers = lambda ns: [tier]
    ctf.load_idle_declarations = lambda: decl
    ctf.broker_topics = lambda ns, t: {TOPIC}
    ctf.projector_mappings = lambda ns, t: [(TOPIC, "tier-projector-x")]
    ctf.direct_ingest = lambda ns, t: True
    ctf.stale_keyed_rows = lambda *a: []
    ctf.null_keyed_relayed = lambda *a: []
    ctf.unentitled_detection = lambda *a: ([], [])
    ctf.watermark = lambda *a: 0
    ctf.TIER_SUBSCRIPTIONS = []
    ctf.read_sim_config = lambda ns: cfg
    ctf.read_edge_assets = lambda ns, t: rows
    buf = io.StringIO()
    rc = None
    try:
        with contextlib.redirect_stdout(buf):
            rc = ctf.main()
    finally:
        for k, v in saved.items():
            if v is None and k not in ("read_sim_config", "read_edge_assets"):
                delattr(ctf, k)
            else:
                setattr(ctf, k, v)
    return rc, buf.getvalue()


class Profiled(unittest.TestCase):
    def test_zero_profiled_is_measured_idle(self):
        rc, out = run_main((CFG % "edge", ""),
                           ([("HMMWV", ""), ("M1A1", "")], ""))
        self.assertIn("idle/measured", out)
        self.assertIn("(hw 0, 0 profiled assets at edge-01)", out)
        self.assertNotIn("NOT FLOWING", out)
        self.assertEqual(rc, 0)

    def test_one_profiled_is_a_finding(self):
        rc, out = run_main((CFG % "edge", ""),
                           ([("MRAD_Sensor", SENSOR)], ""))
        self.assertIn("(hw 0, 1 profiled asset(s) at edge-01, topic empty)",
                      out)
        self.assertEqual(rc, 1)

    def test_subsystem_gate_excludes_sensor_without_subsystem(self):
        rc, out = run_main((CFG % "edge", ""),
                           ([("MRAD_Sensor", ""),
                             ("MRAD_Sensor", "ASSET_SUBSYSTEM_OTHER")], ""))
        self.assertIn("(hw 0, 0 profiled assets at edge-01)", out)
        self.assertEqual(rc, 0)

    def test_profile_without_subsystem_counts_any(self):
        rc, out = run_main((CFG % "edge", ""),
                           ([("MRAD_Interceptor", "")], ""))
        self.assertIn("1 profiled asset(s)", out)
        self.assertEqual(rc, 1)

    def test_store_unreadable_is_a_finding(self):
        rc, out = run_main((CFG % "edge", ""),
                           (None, "store unreadable: boom"))
        self.assertIn("cannot measure profiled assets: store unreadable", out)
        self.assertEqual(rc, 1)

    def test_config_unreadable_is_a_finding(self):
        rc, out = run_main((None, "config map unreadable: nope"), ([], ""))
        self.assertIn("cannot measure profiled assets: config map", out)
        self.assertEqual(rc, 1)

    def test_unparseable_config_is_a_finding(self):
        rc, out = run_main(("garbage: true\n", ""), ([], ""))
        self.assertIn("cannot measure profiled assets: unparseable", out)
        self.assertEqual(rc, 1)

    def test_publish_tier_not_edge_is_undeclared(self):
        rc, out = run_main((CFG % "region", ""), ([], ""))
        self.assertIn("(hw 0, UNDECLARED)", out)
        self.assertEqual(rc, 1)

    def test_region_tier_unaffected(self):
        rc, out = run_main((CFG % "edge", ""), ([], ""), tier="region-east")
        self.assertIn("declared for region-east", out)
        self.assertEqual(rc, 0)

    def test_parser(self):
        pub, prof = ctf.parse_sim_config(CFG % "edge")
        self.assertEqual(pub, "edge")
        self.assertEqual(prof, [(["MRAD_Sensor", "MRAD_Radar"], SENSOR),
                                (["MRAD_Interceptor"], None)])


if __name__ == "__main__":
    unittest.main()
