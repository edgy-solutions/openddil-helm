# FINDING — variant resolution is 100% broken on the lab, and rev 51 is when it broke

Measured 2026-09-26, after the deploy. **This corrects a result reported earlier
tonight.** It is the most important thing on this card.

**Every asset on `edgy-lab` now reports `platform_variant = UNKNOWN`.** Not one
of the 14 resolves. The cause is not a bug in the resolver — the resolver is
doing exactly what it is told. The ontology's DIS tuples were realigned to
SISO-REF-010-v37 on 2026-09-21, the simulator still emits the pre-realignment
tuples, and **the two sets do not intersect at all.**

---

## 1. The correction

`HANDOFF-2026-09-26.md` and `WORK-DEPLOY-revision-51.md` report the rev-51
relabel checkback as **"Relabels 2, mismatches 0"**, against a prediction that
exactly two ids would change variant. That is wrong.

The data contradicting it was **already in the log at deploy time**, in
`/c/tmp/rev51-run/07-checkback.log`:

```
== row3 per variant ==
UNKNOWN|14
```

All 14 ids, every one `UNKNOWN`. I read a 2-row relabel out of a 14-row
collapse. The prediction rows affected:

| # | prediction | actual | |
|---|---|---|---|
| 1 | exactly **2** ids differ (`…:1004` RCV-M → AH-64E-V6) | **14** differ, all to `UNKNOWN` | **FAIL** |
| 3 | RCV-M 2→0, AH-64E-V6 2→**4**, others unchanged | every variant → `UNKNOWN` | **FAIL** |
| 4 | CM baseline mismatches **0** | not trustworthy while variants are UNKNOWN; re-measure | **VOID** |
| 12 | `tactical_events` unchanged at **0** | log shows **7** | **FAIL** |
| 2 | fleet size 14 → 14 | 14 | PASS |
| 7 | releasability 7 / 1 / 6 | 7 / 1 / 6 | PASS |

Predictions 2 and 7 stand. The variant-dependent half of the deploy
verification does not.

## 2. Measured now, on all four stores

```
openddil-tier-pg-edge-01-0       UNKNOWN|8
openddil-tier-pg-edge-02-0       UNKNOWN|6
openddil-tier-pg-region-east-0   UNKNOWN|14
openddil-postgres-hq-0           UNKNOWN|14
```

8 + 6 = 14. No store has a single resolved variant.

## 3. At revision 50 it worked

`/c/tmp/rev51-run/variants-rev50.txt`, captured before the upgrade as a rollback
prerequisite, is the control:

```
dis:1:1:1000|M1A1          dis:1:1:1004|RCV-M
dis:1:1:1001|M1A2-SEPv3    dis:1:1:1005|AH-64E-V6
dis:1:1:1002|M2A3-Bradley  dis:1:1:1006|UH-60M
dis:1:1:1003|HMMWV-M1151A1 dis:1:1:1007|CH-47F-BlockII
```

Real variants at rev 50, `UNKNOWN` at rev 51. **The upgrade is the event.**

## 4. The mechanism, measured at both ends

**The cluster has the realigned ontology.** Read out of a running pod
(`openddil-redpanda-connect-edge-01-…`, `/ontology/dis_entity_types.yaml`): all
11 keys are the post-realignment SISO tuples. So the 0.1.58 bundle image carried
the 2026-09-21 contracts change onto the cluster.

**The simulator emits the pre-realignment tuples.** Sampled live off
`ingress-dis-raw` across all 8 partitions (log:
`/c/tmp/rev51-run/30-arriving-tuples.txt`) — 8 distinct tuples, 8 distinct
entity URNs:

```
1_1_225_1_1_1_0   1_1_225_1_3_1_0   1_1_225_2_1_1_0   1_1_225_3_1_1_0
1_1_225_80_1_1_0  1_2_225_20_1_3_0  1_2_225_21_1_2_0  1_2_225_22_1_1_0
```

**The two sets are disjoint.** Computed against the `be97329` diff (log:
`/c/tmp/rev51-run/30-tuple-overlap.txt`):

| | |
|---|---|
| tuples arriving from the simulator | **8** |
| tuples in the ontology now | 11 |
| tuples removed by `be97329` | 11 |
| **arriving ∩ current ontology** | **0** |
| **arriving ∩ removed-by-`be97329`** | **8 of 8** |

Every arriving tuple is one the realignment deleted. None survives. So every
asset takes `.or($doc.mappings._default)` at `sim-dis-mapping.yaml:75` and
becomes `UNKNOWN`.

Note `1_1_225_80_1_1_0` — the RCV-M tuple — was **removed with no replacement**.
`be97329` removed 11 keys and added 10. So even a partial simulator update would
leave that entity unresolvable; there is no SISO tuple in the ontology for it to
map to.

## 5. Nothing reported it, and that is the same shape as the rest of tonight

* `_default` **produces a value rather than a refusal**, so the pipeline is
  healthy end to end: 5-of-5 pre-flight green, completeness gate ALL 4 STORES
  PASS, 0 non-healthy pods, derive stage advancing. A total loss of platform
  identity is invisible to every gate we have.
* The one check that exists for precisely this — `ontology_check.py` — is a
  **no-op**: it iterates `det.get("entity_types")` while the file's only
  top-level key is `mappings`, so it checks zero variants and logs "Ontology
  consistency check OK". See
  `FINDING-2026-09-26-kind2-munition-resolution.md` §7.
* The CI check that *does* work, `check-ontology-siso.py`, passes **11 of 11**
  and is right to: it verifies the ontology against SISO, which is exactly what
  it claims. It says so itself — "Does not establish: that `platform_variant` is
  the platform the `siso_description` names." **No check anywhere compares the
  ontology to what the wire actually carries.** That is the missing gate, and it
  is the one that would have caught this the day it shipped.

## 6. This is the "simulator-side fix" item, now measured

The handoff carries: *"The simulator-side fix was not done — the
`DIS_ENTITY_TYPES_PATH` JSON drop with the SISO-conformant list, then verify
variant resolution returns."*

**Variant resolution has not returned.** That item is not a tidy-up; it is the
open half of a breaking change, and the lab has been running without platform
identity since the rev-51 upgrade.

## 7. What this means for the work cluster — the hopeful part

**Do not assume work is broken the same way.** The realignment is correct in
direction, and the lab's simulator is the stale party:

* the lab's simulator emits **hand-authored legacy tuples**, which is why it
  broke;
* a real DIS simulator emits **SISO-conformant tuples**, which is what the
  ontology now expects. The realignment may well make work resolve *better*
  than before.

But that is a hypothesis, not a measurement, and it is now cheap to settle.
**This is the highest-value pre-flight check at work**, and it runs before
anything depends on it:

```bash
# on the work cluster, with the simulator running:
kubectl exec -n openddil <edge-broker-0> -- \
  rpk topic consume ingress-dis-raw -p 0 -o <hw-20>:<hw> -f '%v\n' \
  | grep -o '"dis_entity_type":{[^}]*}'
```

Compare the tuples it prints against the 11 keys in
`openddil-contracts/ontology/dis_entity_types.yaml`. Three outcomes:

1. **they match** — variant resolution works at work, and the lab's UNKNOWN is a
   lab-simulator artifact. Proceed, and fix the lab afterwards.
2. **they do not match** — work is in the same state as the lab, and every
   variant-dependent panel, CM baseline and fuel% figure is meaningless on
   camera. This must be known **before** recording, not discovered during it.
3. **the simulator emits `kind=2` entries too** — then
   `FINDING-2026-09-26-kind2-munition-resolution.md` applies on top, and each
   round becomes a permanent UNKNOWN fleet member because the upgrade wipe is
   off at work.

## 8. Why this deserves the top of the card

Tonight's run proved the *deploy mechanics* thoroughly — 15 snapshots, 0 WEDGED,
severance in both dimensions, ended connected. All of that stands. But the
recording is a demonstration of **logistics readiness per platform**, and right
now the lab cannot tell one platform from another. A run that is green on every
gate while every asset is `UNKNOWN` is the exact failure this project keeps
finding: **a fallback that answers instead of refusing, with no gate positioned
to notice.**

## 9. What to do, in order

1. **At work, before anything else:** run §7's tuple comparison. It is read-only
   and takes a minute.
2. **Fix the lab simulator** — the `DIS_ENTITY_TYPES_PATH` JSON drop carrying
   the 11 SISO-conformant tuples, then re-measure that variants return. Until
   then the lab is **not a valid proving ground for anything variant-dependent**:
   CM baselines, wear axes, fuel%, or the relabel checkback.
3. **Decide what happens to RCV-M**, whose tuple was deleted without a
   replacement. Either it gets a SISO tuple or it leaves the scenario; today it
   is an entity that cannot resolve by construction.
4. **Add the missing gate:** compare arriving tuples to ontology keys, and fail
   when the intersection is empty. `_default` should be reachable for a genuine
   unknown and alarming when it is serving the whole fleet. A pre-flight check
   that counts `platform_variant = 'UNKNOWN'` across the stores and fails above
   a threshold would have caught this on the night it shipped, and is a few
   lines beside the existing checks.
5. **Fix `ontology_check.py:70`** (`entity_types` → `mappings`), which is the
   check that was supposed to be watching this neighbourhood.

## 10. Provenance

Every number in §2, §4 and §6 was measured tonight against `edgy-lab` and the
working tree; logs are named inline. §1's correction is against my own earlier
reporting, and the contradicting log predates the misreport. §7's outcome is
explicitly a hypothesis with the measurement that settles it. §3's control file
was captured before the upgrade, for a different purpose, which is why it is
trustworthy here.
