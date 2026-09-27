# Finding — `trim-prefix` is refused on compacted topics, so phase 4 cannot clear the state topics

**Status: blocker. `reset-scenario.sh` phase 4 does not work, and the fix is a
design decision, not a patch.**

Measured on the lab, 2026-09-26 (runs at 23:20-23:44 local). The script is otherwise complete and every other
phase's check is now falsifiable; this is the one thing standing between it and a
proven round trip.

## What happens

Phase 4 trims each partition to its high watermark. On the first compacted topic:

```
-> trim asset-cm-state partition 0 on <broker>: log_start 0 -> 217062
TOPIC           PARTITION  NEW-START-OFFSET  ERROR
asset-cm-state  0          -                 POLICY_VIOLATION: Request parameters
                                             do not satisfy the configured policy.
```

Cause, read off the topic itself:

```
cleanup.policy    compact    DYNAMIC_TOPIC_CONFIG
```

Redpanda refuses the Kafka `DeleteRecords` request — which is what `rpk topic
trim-prefix` issues — on a topic with `cleanup.policy=compact`. This is the
documented Kafka behaviour, not a Redpanda quirk.

## Why it is a blocker rather than an inconvenience

The compacted topics are the state topics. Measured across all five brokers:
**53 compacted partitions, 57 delete-policy, 4 `compact,delete`.** The compacted
set includes `telemetry-latest-state`, `asset-cm-state`,
`asset-logistics-status`, `asset-capability-snapshot`,
`asset-element-inventory`, `asset-element-telemetry`, `asset-registry-events`,
`cm-items`, `region-fleet-summary`, `region-top-factors`, `region-wear-trends`,
and every Faust `*-changelog`.

Those are precisely the topics a scenario reset exists to clear. Trimming only the
delete-policy topics would leave the latest-per-key state of the entire fleet in
place and report success on everything it did touch.

## Four options, none taken

The PREDICTION doc chose trim specifically to *avoid* delete-and-recreate. That
choice is sound for delete-policy topics and simply unavailable for compacted
ones, so the decision has to be re-made for that half:

1. **Delete and recreate.** Reproduces the topic exactly only if its full config
   is replayed. There is already a parallel topic-spec matrix in one other
   script, and the drift risk between it and the chart's topic configs is a known
   hazard; adding a third copy makes it worse. Mitigable by reading each topic's
   live config immediately before deleting and replaying it, which is drift-free
   by construction but loses consumer group offsets.
2. **Tombstone per key.** Semantically the *right* way to empty a compacted
   topic, and what the topics are designed for. Requires enumerating every key,
   and does not shrink the log until compaction runs, so the verify would have to
   assert something other than `log_start == high_watermark`.
3. **Temporarily `alter-config cleanup.policy=delete`, trim, set it back.** Uses
   the existing mechanism, preserves partitions, replication and offsets, needs no
   config matrix. The risk is specific and bad: a failure between the two alters
   leaves the topic with the wrong retention policy — a half state in *config*
   space, on the mechanism whose entire purpose is to not leave half states.
4. **Don't clear compacted topics at all**, and rely on clearing the consumers
   (stores deleted, Restate state cleared, Faust restarted). Cheapest, and
   defensible if every consumer really does rebuild from its own store rather
   than from the topic — but the Faust changelogs are themselves compacted, which
   is how the regional rollup keeps its pre-reset `asset_count`. So this option
   has to answer the §5 red-check before it can be chosen.

Nothing was patched. Options 1 and 3 both introduce a new mutation path on the
mechanism a live demo restarts on, and 2 and 4 change what the verify asserts.

## Also measured: one broker's state topics are not compacted at all

Seven state topics are `compact` on `edge-01`, `edge-02`, `edge-03` and `hq`, and
`delete` on `region-east`:

| topic | edge-01 | edge-02 | edge-03 | hq | region-east |
|---|---|---|---|---|---|
| `asset-cm-state` | compact | compact | compact | compact | **delete** |
| `asset-logistics-status` | compact | compact | compact | compact | **delete** |
| `telemetry-latest-state` | compact | compact | compact | compact | **delete** |
| `region-fleet-summary` | compact | compact | compact | compact | **delete** |
| `region-top-factors` | compact | compact | compact | compact | **delete** |
| `region-wear-trends` | compact | compact | compact | compact | **delete** |
| `asset-registry-events` | compact | compact | compact | compact | **delete** |

One broker of five, all seven, same direction — so it is one creation path that
did not carry the topic configs, not seven independent mistakes.

Independent of the reset, this means region-east's state topics grow without
bound and anything rebuilding state from the start of those logs reads full
history rather than latest-per-key. It is the topic-spec drift hazard already on
the books, now with a measured signature. It also means phase 4 *appears* to work
on region-east and fails on the other four, which is the most confusing possible
failure distribution.

## State of the script otherwise

Phases 1, 2, 3 and the whole of 9 ran clean on the lab. Nine judgment calls
resolved by measurement (six by review, three by running). Verified working:
`--json` parsing, the measured 30s Restate re-arm cadence, `restate -y`, Restate
runtime discovery by container name, the real Electric shape check on
per-instance ports, the protobuf-aware aggregator check with a database-clock
freshness boundary, and `rpk --no-confirm`.

Phase 4 is the only phase that has never completed.
