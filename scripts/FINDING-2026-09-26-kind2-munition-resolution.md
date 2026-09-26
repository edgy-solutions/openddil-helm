# FINDING — what happens when a munition arrives as `kind=2`

Measured 2026-09-26. This is the question the work session needs answered
**before the work simulator sends anything**, because the answer composes with
tonight's no-eviction finding into a permanent effect.

**Short answer.** A munition is not rejected and not recognised. It resolves to
`_default`, becomes `platform_variant=UNKNOWN`, and enters the fleet as an
asset. Nothing anywhere warns. But the raw `kind=2` **does** survive to Silver,
so the discriminator needed to fix this is already on the wire.

---

## 1. The claim that was on the books

`openddil-contracts/decisions/DESIGN-2026-08-11-declared-asset-class.md:106`:

> a fired round arriving as `kind=2` matches no entry, falls to `_default`, and
> becomes `UNKNOWN` platform metadata

That is a prediction from reading code, and GD-11 records the whole area as
**design-only, nothing built**. It had not been measured.

## 2. Why the existing test does not answer it

`openddil-demo/tests/hero_scenario_v3/test_05_ontology_fallback.py` proves a
fallback already — but with `kind=9, country=999`, which its own comment calls
"self-evidently unknown". It answers *does nonsense fall back*. It does not
answer *does a plausible munition fall back*, which is the case the work
simulator will actually produce.

## 3. The probe tuple, chosen to isolate one variable

| | tuple | resolves to |
|---|---|---|
| M1A1, a recognised platform | `1_1_225_1_1_2_0` | `M1A1` |
| **the munition probe** | **`2_1_225_1_1_2_0`** | **`UNKNOWN`** |

Identical in all six trailing elements. **`kind` is the only difference**, so
the outcome is attributable to `kind` alone and to nothing else about the
tuple's plausibility.

## 4. Measured at the resolver

Against the real `openddil-contracts/ontology/dis_entity_types.yaml`, with the
lookup replicated exactly from `openddil-demo/dynamic-mappings/sim-dis-mapping.yaml`
lines 54–96. Log: `/c/tmp/rev51-run/27-kind2-resolver.txt`.

| # | prediction | measured |
|---|---|---|
| — | mapping entries | **11**, kinds present **[1]**, `kind=2` entries **0** |
| 2 | `platform_variant` | **`UNKNOWN`** PASS |
| 3 | `configuration_baseline` | `''` PASS (from `default_baseline: null`) |
| 4 | `cbm_schema` | `''` PASS |
| 5 | `platform_type` | `'Unrecognized DIS entity type — requires ontology curation'` PASS |
| 6 | raw `dis_entity_type.kind` | **`2`, carried through** PASS |

**One source of truth.** `find` returns exactly one `dis_entity_types.yaml`, in
`openddil-contracts/ontology/`. The demo overlay does **not** ship its own copy,
so compose and both clusters read the same file and the gap is not
environment-specific.

## 5. Two things the design doc does not say

**(a) A munition and a corrupt platform are byte-identical at the resolver.**
`sim-dis-mapping.yaml:75` is `.get($triple).or($doc.mappings._default)` — an
unconditional fallback with **no refusal branch**. The probe tuple and
test_05's garbage tuple resolve to the *same object*: measured identical
field-for-field, same `_default` row. So at the point of classification there
is no signal distinguishing "a round was fired" from "a platform arrived
malformed". `_default` produces a value rather than a refusal, which is the
failure mode §1 of the provenance audit already names.

**(b) The raw `kind` survives, and that is the good news.**
`sim-dis-mapping.yaml:90–96` copies all seven tuple elements to Silver
untouched, and the proto field is `uint32`. So **detecting a munition needs no
schema change, no new field and no renumbering** — only a reader. Every
ingredient for the fix is already arriving; nothing consults it.

## 6. Walking the path to the readers

Per the EXCHANGE-LEDGER standing check, an absence measured at one end
localizes nothing. §4 measures the *producer* of the classification; these are
the readers between it and the fleet.

* **`openddil-sensor-ingest/dis_ingestor.py:461`** drops every PDU whose type
  is not 1: `if pdu_type != 1: ... continue`, at DEBUG. So **Fire (type 2) and
  Detonation (type 3) PDUs never enter the system at all.** The kind=2 path is
  reachable *only* through an Entity State PDU for a munition entity — which a
  simulator does emit for a tracked round in flight. Worth knowing precisely:
  the firing *event* is invisible, but the round *as an entity* is not.
* **No runtime refusal of `UNKNOWN` exists anywhere downstream.** Grep across
  the fusion service, the tactical agents and the dynamic mappings finds no
  guard that drops or quarantines an UNKNOWN variant. `rules.py:339` documents
  the opposite intent — UNKNOWN wear axes are the honest default and emission
  continues.
* **The one check that names this file is silently covering nothing.** See §7.

## 7. Separate bug found while walking the path: the ontology drift check is a no-op

`openddil-logistics-fusion-service/src/fusion/ontology_check.py:70` reads

```python
for entry in det.get("entity_types") or []:
```

but `dis_entity_types.yaml`'s only top-level key is **`mappings`**. Measured:

```
top-level keys                     : ['mappings']
entity_types present               : False
det.get('entity_types') yields     : []  -> loop body never runs
```

So the loop never executes and **zero of the DIS ontology's variants are
checked**, although the module docstring names `dis_entity_types.yaml` as one
of the two files it covers. Worse than silent: the function then takes the
`if not missing` branch and logs **"Ontology consistency check OK"**.

What it should have been reporting — `platform_reference.yaml` holds only 3
platforms against 10 named variants (log:
`/c/tmp/rev51-run/27-ontology-check-bug.txt`):

| | |
|---|---|
| variants resolved | **1** — `M1A2-SEPv3` |
| variants missing a `platform_reference` entry | **9** |

`AH-64E-V6`, `CH-47F-BlockII`, `F-16C-Block50`, `F-35A-Block4`,
`HMMWV-M1151A1`, `M1A1`, `M2A3-Bradley`, `MQ-9A-Block5`, `UH-60M`.

Note `AH-64E-V6` against the reference's `AH-64E` — a near-miss name, exactly
what this check exists to catch. Per the check's own warning text, the
consequence of each is that "Fuel% evaluation for assets with this variant will
fall back to env override (if present) or be skipped."

The fix is one identifier. It is **not** a drive-by change: turning it on emits
9 new startup warnings, so it wants to land deliberately, with either the
`platform_reference` entries added or the warnings expected.

## 8. The compose leg is blocked, and was not substituted

The dispatch asked for this "proven under compose". **It is not**, and I did not
quietly run it somewhere else instead.

Docker Desktop's UI processes start, but the privileged Windows service
`com.docker.service` is `Stopped` with `StartType: Manual`, the `docker-desktop`
WSL distro is `Stopped`, and `Start-Service` returns

```
Cannot open com.docker.service service on computer '.'
```

— access denied; it needs elevation. I did not escalate unattended.

**The probe is written and ready to run in one command** once the daemon is up:

```bash
py -3 /c/tmp/rev51-run/kind2_probe.py
```

It sends the §3 tuple with marker `entity=2099`, marking `MUNITION-X`, reads
`raw-sensor-stream`, and checks P1–P6. It imports the repo's own
`hero_scenario_v3/_helpers.py`, so the PDU layout and the Windows
UDP-black-hole socat dodge are the ones the hero tests already use, and it
lives in `/c/tmp/` so **nothing was added to the repo**. Minimal bring-up is
the ingress leg only, not all 40 services:

```bash
docker compose -f openddil-demo/docker-compose.yml up -d \
  openddil-sensor-ingest-01 redpanda-connect-01
```

which pulls in `redpanda-edge-01`, `redpanda-init`, `toxiproxy` and
`ontology-overlay` by `depends_on`.

**What remains unproven without it:** that the transport behaves as the
resolver says — that the event actually lands on `raw-sensor-stream`, and that
an `AssetLogistics` object is actually created for the round. §4 proves the
classification; it does not prove delivery. Prediction 1 is the open one.

## 9. Why this matters at work specifically

The composition, not any single fact:

1. a munition entity arrives as an Entity State PDU and **is accepted**;
2. it resolves to `UNKNOWN` with **no warning and no refusal** (§4, §5, §6);
3. an asset once seen is **permanent** — `AssetLogistics.on_timer` re-emits with
   `force_emit=True` and reschedules unconditionally, and there are no deletion
   semantics anywhere (`FINDING-2026-09-26-no-asset-eviction.md`);
4. **at work `restate.ephemeralOnUpgrade` is false by default**, so unlike the
   lab it is not cleared by the next upgrade;
5. and no completeness gate can see it — the aggregate tables invert the
   nation test, which is why tonight's `dis:1:1:1099` residue passed every gate
   for days.

So on the work cluster, **every round the simulator tracks in flight is a
candidate permanent UNKNOWN fleet member**, inflating rollups indefinitely with
nothing that reports it. That is the same shape as the residue cleared in the
lab tonight, arriving by a supported path rather than a spurious one.

## 10. What to do, in order of cost

* **Cheapest, before the work deploy:** know the number. Count Entity State
  PDUs with `kind=2` the simulator emits in a representative run. If it emits
  none, this is latent and can wait; if it emits one per shot, the fleet grows
  monotonically for the length of the recording.
* **Cheap and reversible:** the `kind=2` case belongs in
  `test_05_ontology_fallback.py` as a second case beside the garbage tuple —
  two guards for the price of one, exactly as the design doc argues at its
  "testable today" paragraph. A munition case proves the path is *visible* now,
  and proves the new entries resolve on the day the ontology is extended.
* **The real fix, an ontology PR per ADR-0016:** add munition-kind entries so
  `kind=2` resolves. §5(b) is the reason this is cheap — the tuple already
  arrives intact.
* **Independent of all of the above:** fix `ontology_check.py:70`, §7.

## 11. Provenance

Everything in §4 and §7 was measured tonight against files in the working tree,
by scripts kept in `/c/tmp/rev51-run/` (`kind2_resolver_proof.py`,
`kind2_probe.py`). §1's claim is quoted, not adopted. §8 states plainly what was
not run. Prediction written before measuring:
`/c/tmp/rev51-run/27-PREDICTION-kind2.md`.
