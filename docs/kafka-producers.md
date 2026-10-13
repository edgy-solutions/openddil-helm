# Kafka producers: every producer fails fast, or has a row saying why not

## The rule

A Kafka producer in a long-running service must do one of two things:

1. **Fail fast** on a producer error it cannot recover from: exit the process so the orchestrator restarts it.
2. **Or have a row in this table** saying why that does not apply.

Background. An idempotent librdkafka producer can enter a fatal state, for example after a broker restart with
batches in flight. From then on every produce fails while the process stays up, so the service keeps consuming and
decoding into a client that can never publish again. Only a restart clears it. Delivery errors that are logged and
swallowed look like transient noise and hide the wedge.

Reference implementations:

- `openddil-cm-service/src/producer_health.py` and `openddil-logistics-fusion-service/src/producer_health.py`: exit 70
  on a fatal error, plus a `/healthz/live` stall rule on confirmed delivery (not on a successful `produce()` call).
- `openddil-sensor-ingest/dis_ingestor.py` + `stall.py`: the same shape (`_die_if_fatal` at L333, exit 70 at L341,
  stall detector wired to liveness).

All paths below are relative to the repository root that contains the sibling repos (`openddil-*`).

## Reading the table

- **Library**: confluent-kafka, aiokafka, kafka-python, Confluent.Kafka, or connect (Redpanda Connect / Benthos).
- **Idempotence**: quoted from the config. "explicit" means the conf sets it; "defaulted" means it is absent and the
  library default applies. Library defaults: confluent-kafka (librdkafka) `enable.idempotence=false`; aiokafka
  `enable_idempotence=False`; Confluent.Kafka `EnableIdempotence=false`; the connect `kafka_franz` output
  `idempotent_write` defaults to true per the component docs (not exercised here); the legacy connect `kafka` output
  has no idempotence setting (non-idempotent).
- **Chart**: matched by image name and command/args against `openddil-helm/openddil-demo/templates/*.yaml`. The
  image name comes from `values.yaml` (`sensorIngest`, `cmService`, `logisticsFusion`, `assetRegistry`,
  `logisticsSim`, `projector`, `egress`, `faustRegional`, `redpandaConnect`); connect configs are matched by the
  bundle path in `openddil.bundleInit` (`src`) or by the helper that renders them.
- **Liveness**: `livenessProbe` on that workload in the template (path or mechanism). Uncommitted chart changes that
  add `/healthz/live` probes to cm-service and logistics-fusion are counted as present.
- Sites that only *consume* (connect `input:` blocks) are not producers and are excluded; only `output:` blocks count.
  The `kafka:` key in `openddil-regional-stack/docker-compose.yml:96` is a console config, not a producer.

## The table

| # | repo:path:line | library | idempotence | deployed by the chart? | fails fast? | liveness probe? | verdict |
|---|---|---|---|---|---|---|---|
| 1 | openddil-sensor-ingest:dis_ingestor.py:367 | confluent-kafka | explicit `"enable.idempotence": True` (L357) | Yes: edge.yaml:66 Deployment `sensor-ingest-<edge>`; image `sensor-ingest`, `command: ["python","dis_ingestor.py"]` | Yes: `error_cb` (L358) and delivery cb (L394) call `_die_if_fatal` → `_exit_process(70)` (L341) | Yes: edge.yaml:179, httpGet `/healthz/live` (stall rule, `stall.note_output()` at L407) | FAILS FAST |
| 2 | openddil-sensor-ingest:asterix_ingestor.py:153 | confluent-kafka | explicit `"enable.idempotence": True` (L148) | No: same image, but the chart's command is `dis_ingestor.py` and nothing in the chart references `asterix_ingestor` | No: no `error_cb`; `_on_delivery` (L167) only counts and logs | n/a | WHY NOT: not deployed by the chart (alternate entrypoint, not run by any template). Would be a GAP if deployed. |
| 3 | openddil-sensor-ingest:dds_ingestor.py:44 | confluent-kafka | defaulted (false); conf sets `retries`, `message.timeout.ms`, no idempotence key | No: no template references `dds_ingestor` | No: `delivery_report` logs only | n/a | WHY NOT: not deployed by the chart (alternate entrypoint). Non-idempotent. |
| 4 | openddil-cm-service:src/main.py:97 | confluent-kafka | explicit `"enable.idempotence": True` (L94) | Yes: hub.yaml:376 Deployment `cm-service`; tier-node.yaml:1504 Deployment `tier-cm-<tier>`; image `cm-service` | Yes: `error_cb` (L95) and `_on_delivery` call `producer_health.die_if_fatal` → exit 70 (`producer_health.py:84`) | Yes: hub.yaml:417 and tier-node.yaml:1548, httpGet `/healthz/live` | FAILS FAST |
| 5 | openddil-cm-service:cli/submit_cm_event.py:116 | confluent-kafka | defaulted (false); conf is `{"bootstrap.servers","acks":"all"}` | No: CLI, not in any template | Yes (one-shot): `flush(timeout=10)`, process ends after one produce | n/a | WHY NOT: one-shot CLI: a failed produce fails the process (there is no long-running loop). Note the code does not check the delivery result, so a timed-out flush still exits 0. |
| 6 | openddil-logistics-fusion-service:src/main.py:134 | confluent-kafka | explicit `"enable.idempotence": True` (L131) | Yes: hub.yaml:797 Deployment `logistics-fusion-service`; tier-node.yaml:1367 Deployment `tier-fusion-<tier>`; image `logistics-fusion-service` | Yes: `error_cb` (L132) and `_on_delivery` call `producer_health.die_if_fatal` → exit 70 | Yes: hub.yaml:847 and tier-node.yaml:1431, httpGet `/healthz/live` | FAILS FAST |
| 7 | openddil-tactical-agents:regional/source_app.py:506 | aiokafka | defaulted (false); conf is `acks="all"` | Yes: regional.yaml:73 Deployment `faust-regional-<region>`; image `faust-regional`, image entrypoint `faust_regional.py` | Yes (by propagation): `send_and_wait` (L527) is awaited directly in the faust agents (e.g. L228, outside any `try`); an escaping exception ends the agent, and `faust_regional.py:25-29` documents that a crash in any App takes the worker down by design. Not exercised at runtime. | No | FAILS FAST |
| 8 | openddil-tactical-agents:edge/edge_restate_detector.py:30 | confluent-kafka | defaulted (false); conf sets `retries`, `message.timeout.ms` | No: separate image built from `edge/restate/Dockerfile`; no template or compose file names it. The chart's `faust-edge` image runs `faust_edge.py`. | No: `delivery_report` logs only | n/a | WHY NOT: not deployed by the chart. Non-idempotent. |
| 9 | openddil-stack:asset-registry-service/src/asset_registry_service/registry_app.py:53 | aiokafka | defaulted (false); conf is `acks="all"` | Yes: hub.yaml:618 Deployment `asset-registry-service`; image `asset-registry-service` (`CMD ["asset-registry-service"]`) | No: `hq_producer.send` raising is caught at L272 and logged as a warning (`publish failed`); the row is already in postgres and consumers catch up | No | WHY NOT: non-idempotent client: no fatal state; a failed publish is logged and the state is re-published from postgres on the next observation or consumer startup (comment at L273-276). Not exercised. |
| 10 | openddil-logistics-sim:src/logistics_sim/publisher.py:185 (constructed via `HqProducer(` at src/logistics_sim/main.py:229; also once per edge broker in `start()`) | aiokafka | explicit `enable_idempotence=False` (L188) | Yes: logistics-sim.yaml:57 Deployment `logistics-sim`; image `logistics-sim` | No: every `publish_*` call is wrapped; failures are caught with `log.exception` and retried on the next tick (main.py:118-121, 138-139, 152-153, 204-205). The exception does not escape. | No | WHY NOT: non-idempotent client: no fatal state; errors surface as logged exceptions and the next tick republishes the full snapshot. Not exercised. |
| 11 | openddil-projector:src/edge_buffer_monitor.py:485 | confluent-kafka | defaulted (false); conf is `{"bootstrap.servers"}` only | Yes: edge.yaml:677 Deployment `projector-<edge>`; hub.yaml:1006 Deployment `projector-hq`; tier-node.yaml:609 Deployment `tier-projector-<tier>`; image `projector` (this producer only runs when the link heartbeat is enabled) | No: best-effort heartbeat; `except Exception` logs once (`_warn_once`) and loops | No | WHY NOT: non-idempotent client: no fatal state; the producer is only the link heartbeat, and a missing heartbeat is itself the signal the consumers read. |
| 12 | openddil-demo:egress/main.py:291 | confluent-kafka | defaulted (false); conf is `{"bootstrap.servers"}` | Yes: egress.yaml:53 Deployment `egress-gate-c2`; image `egress`, no command override (image `CMD ["python","/app/main.py"]`, Dockerfile:142) | Yes (by propagation): `delivery.send_one` flushes and raises `DeliveryFailed` (delivery.py:91-93); `routes.py:194-201` logs and re-raises; `main()` has only `try/finally` (L296-320), so the process exits nonzero before the offset commit | No | FAILS FAST |
| 13 | openddil-demo:egress/assembler.py:1251 | confluent-kafka | defaulted (false); conf is `{"bootstrap.servers"}` | Yes: egress.yaml:266 Deployment `egress-assembler`; image `egress`, `command: ["python","-u","/app/assembler.py"]` | Yes (by propagation): `produce` → `delivery.send_one` raises `DeliveryFailed` out of `handle_cm_state_message`; the loop (L1257-1297) has only `try/finally`, and the comment at L1281-1285 states the offset is not committed | No | FAILS FAST |
| 14 | openddil-demo:egress/intake.py:989 | confluent-kafka | defaulted (false); conf is `{"bootstrap.servers"}` | Yes: egress.yaml:422 Deployment `egress-intake`; image `egress`, `command: ["python","-u","/app/intake.py"]` | No: `DeliveryFailed` is caught at intake.py:733-737, logged, counted as `delivery_failed`, and the loop `continue`s | No | WHY NOT: non-idempotent client: no fatal state; each produce is flushed and confirmed, a failed one is not stored, so the same artifact is re-decided and re-produced on the next poll. |
| 15 | openddil-demo:simulator/fleet_simulator.py:45 | confluent-kafka | defaulted (false); conf is `bootstrap.servers`, `client.id` | No: not referenced by any template or compose file | No | n/a | WHY NOT: not deployed by the chart (dev/compose only). Non-idempotent. |
| 16 | openddil-demo:simulator/ltamds_simulator.py:24 | confluent-kafka | defaulted (false); conf is `bootstrap.servers`, `client.id` | No: not referenced by any template or compose file | No | n/a | WHY NOT: not deployed by the chart (dev/compose only). Non-idempotent. |
| 17 | openddil-edge-python:src/openddil_edge/relay_agent.py:70 | aiokafka | explicit `enable_idempotence=True` (L73) | No: a library embedded by edge applications; no template names it | No: `KafkaError` per message is caught, the batch breaks and retries on the SAME producer (L108-114); only a non-`KafkaError` exception rebuilds the producer | n/a | WHY NOT: not deployed by the chart (library). See "Library producers" below: an embedding service inherits this behaviour. |
| 18 | openddil-edge-dotnet:src/OutboxRelayService.cs:85 | Confluent.Kafka | explicit `EnableIdempotence = true` (L65) | No: a library embedded by edge applications; no template names it | No: `ProduceException` per message is caught, the batch breaks and retries on the SAME producer; no `SetErrorHandler`, no `IsFatal` check | n/a | WHY NOT: not deployed by the chart (library). See "Library producers" below. |
| 19 | openddil-helm:openddil-demo/templates/_helpers.tpl:1126 (`openddil.edgeBridgeConnectYaml`) | connect (`kafka` output, sarama) | defaulted: no idempotence field; `max_retries: 0` | Yes: edge.yaml:515 Deployment `edge-hq-bridge-<edge>`; matched by the include at edge.yaml:508 | No in-process mechanism; the pod is restarted by the probe | Yes: edge.yaml:596, exec `/probe/relay-stall-probe.sh` (input advanced, confirmed output did not, destination reachable) | WHY NOT: connect: the output retries and the relay-stall liveness restarts it |
| 20 | openddil-helm:openddil-demo/templates/_helpers.tpl:1273 (`openddil.tierUplinkConnectYaml`) | connect (`kafka` output, sarama) | defaulted: no idempotence field; `max_retries: 0` | Yes: tier-node.yaml:2244 Deployment `tier-uplink-<tier>`; matched by the include at tier-node.yaml:2240 | No in-process mechanism; the pod is restarted by the probe | Yes: tier-node.yaml:2303, exec `/probe/relay-stall-probe.sh` | WHY NOT: connect: the output retries and the relay-stall liveness restarts it |
| 21 | openddil-demo:openddil-base-connect.yaml:110 (`ingress-dlq`) | connect (`kafka_franz`) | defaulted (`idempotent_write` not set; component default true) | Yes: edge.yaml:250 Deployment `redpanda-connect-<edge>`; matched by `openddil.bundleInit` `src: demo/openddil-base-connect.yaml` → `connect.yaml` (edge.yaml:309) | No: the output retries; on persistent failure input backpressures; the process stays up | Yes: exec `/probe/relay-stall-probe.sh` (two-term, METRICS_URL on the mapper's own port; sums every input and output series: the mapper has a broker input and a switch output) | WHY NOT: connect: the output retries and the relay-stall liveness restarts it |
| 22 | openddil-demo:openddil-base-connect.yaml:120 (`effector-events`) | connect (`kafka_franz`) | defaulted (as row 21), `max_in_flight: 64` | Yes: same Deployment as row 21 | No (as row 21) | Yes: exec `/probe/relay-stall-probe.sh` (two-term, METRICS_URL on the mapper's own port; sums every input and output series: the mapper has a broker input and a switch output) | WHY NOT: connect: the output retries and the relay-stall liveness restarts it |
| 23 | openddil-demo:openddil-base-connect.yaml:126 (`raw-sensor-stream`) | connect (`kafka_franz`) | defaulted (as row 21), `max_in_flight: 64` | Yes: same Deployment as row 21 | No (as row 21) | Yes: exec `/probe/relay-stall-probe.sh` (two-term, METRICS_URL on the mapper's own port; sums every input and output series: the mapper has a broker input and a switch output) | WHY NOT: connect: the output retries and the relay-stall liveness restarts it |
| 24 | openddil-demo:cm-intake.yaml:94 | connect (`kafka` output, sarama) | defaulted: no idempotence field; `ack_replicas: true`, `max_in_flight: 1` | Yes: hub.yaml:492 Deployment `cm-intake`; tier-node.yaml:1612 Deployment `tier-cm-intake-<tier>`; matched by `bundleInit` `src: demo/cm-intake.yaml` (hub.yaml:526, tier-node.yaml:1650) | No process exit, but the produce is synchronous to an HTTP caller: per the in-file comment (L87-93) a broker that never acks surfaces as a failed HTTP response, not a 2xx | No | WHY NOT: non-idempotent client: no fatal state; a failed produce is returned to the HTTP caller as an error. Based on the in-file comment and the component's documented behaviour; not exercised. |
| 25 | openddil-demo:benthos-ingest.yaml:24 | connect (`kafka`) | defaulted (no idempotence field); `max_retries: 3` | No: no template or compose file references this file | No | n/a | WHY NOT: not deployed by the chart (dev/compose only). |
| 26 | openddil-demo:redpanda-connect.yaml:12 | connect (`kafka`) | defaulted; `max_retries: 0` | No: no template or compose file references this file | No | n/a | WHY NOT: not deployed by the chart (dev/compose only). |
| 27 | openddil-demo:redpanda-connect-edge-01.yaml:15 | connect (`kafka`) | defaulted; `max_retries: 0` | No: mounted by `docker-compose.yml:560` only | No | n/a | WHY NOT: not deployed by the chart (dev/compose only). |
| 28 | openddil-demo:redpanda-connect-edge-02.yaml:13 | connect (`kafka`) | defaulted; `max_retries: 0` | No: mounted by `docker-compose.yml:577` only | No | n/a | WHY NOT: not deployed by the chart (dev/compose only). |
| 29 | openddil-demo:redpanda-connect-edge-03.yaml:13 | connect (`kafka`) | defaulted; `max_retries: 0` | No: mounted by `docker-compose.yml:594` only | No | n/a | WHY NOT: not deployed by the chart (dev/compose only). |
| 30 | openddil-regional-stack:connect/redpanda-connect.yaml:56 | connect (`kafka_franz`) | explicit `idempotent_write: true` (L68) | No: standalone compose stack (`docker-compose.yml:150`); not a chart template | No | n/a | WHY NOT: not deployed by the chart (compose only). If it is run as a long-lived bridge, it needs the same relay-stall liveness as the chart's bridge. |
| 31 | openddil-customer-bundle-example:connect/connect-sim-a-amqp.yaml:49 | connect (`kafka_franz`) | defaulted (component default true); `max_in_flight: 64` | No: `docker-compose.customer.yml:75` only; the chart takes connect configs from the runtime bundle, not from this example | No | n/a | WHY NOT: not deployed by the chart (compose only, example bundle). |
| 32 | openddil-customer-bundle-example:connect/openddil-customer-connect.yaml:61 (`ingress-dlq`) | connect (`kafka_franz`) | defaulted | No: `docker-compose.customer.yml:97` only | No | n/a | WHY NOT: not deployed by the chart (compose only, example bundle). |
| 33 | openddil-customer-bundle-example:connect/openddil-customer-connect.yaml:65 (`raw-sensor-stream`) | connect (`kafka_franz`) | defaulted; `max_in_flight: 64` | No: `docker-compose.customer.yml:97` only | No | n/a | WHY NOT: not deployed by the chart (compose only, example bundle). |

Counts per repo (rows): sensor-ingest 3, cm-service 2, logistics-fusion-service 1, tactical-agents 2, stack 1,
logistics-sim 1, projector 1, demo 5 python (rows 12-16) + 9 connect (rows 21-29), edge-python 1, edge-dotnet 1,
helm 2, regional-stack 1, customer-bundle-example 3.

Verdict totals: FAILS FAST 6 (rows 1, 4, 6, 7, 12, 13); WHY NOT 27; GAP 0.

## Gaps

None.

- Caveat on rows 21-23: the mapper drops some input by design, so a window in which every arriving PDU is filtered reads as input-advanced/output-flat; it takes 3 consecutive such windows (3 min) to restart, and the remedy is a mapper restart, which is cheap.

## Notes that are not GAP rows

- **Row 24 (`cm-intake`)** is a WHY NOT that rests on a synchronous HTTP response and a non-idempotent client. It has
  no liveness probe, so if that reasoning is wrong in some failure mode nothing restarts the pod.
- **Library producers (rows 17, 18).** Both use an idempotent client and neither inspects fatal errors: a per-message
  error is logged and retried on the same producer instance. A service that embeds them and is deployed by the chart
  would be a GAP. Fixing it would mean treating a fatal producer error as a signal to dispose and rebuild the
  producer (or exit), not only the connection-level exceptions.
- **Rows 9 and 10** swallow the exception from `send_and_wait` on purpose. That is not fail-fast; the WHY NOT rests on
  the client being non-idempotent and on the state being re-published. If either producer is ever made idempotent,
  it needs a fatal-error exit.
- **Row 2 (`asterix_ingestor.py`)** has an idempotent producer with no `error_cb` and a log-only delivery callback.
  It is a GAP the day any template runs it.

## How this table was built

Run from the directory that contains the `openddil-*` repos. Excluded: `wt/`, `_scratch/`, `node_modules`, `.venv`,
and tests.

```sh
# 1. Python producers and connect outputs (all producer constructions, Python + .NET + connect keys)
grep -rnE --include=*.py --include=*.cs --include=*.yaml --include=*.yml --include=*.tpl --include=*.toml \
  -e 'Producer\(|ProducerBuilder|^\s*(kafka|kafka_franz):' . \
  | grep -vE '/(wt|_scratch|node_modules|\.venv|venv)/|/tests?/|test_|_test\.|conftest'

# 2. Other producer class names (expect no hits beyond the above)
grep -rnE --include=*.py 'KafkaProducer\(|AIOKafkaProducer\(' . | grep -vE '/(wt|_scratch|node_modules|\.venv)/|/tests?/|test_'

# 3. Connect blocks are inputs or outputs: classify by the enclosing key
grep -nE '^(input|output):|^\s+(kafka|kafka_franz):' <file>

# 4. Chart deployment matching
grep -nE -A3 '^kind: (Deployment|StatefulSet|Job|DaemonSet|CronJob)' openddil-helm/openddil-demo/templates/*.yaml
grep -n 'livenessProbe' openddil-helm/openddil-demo/templates/*.yaml
grep -rn 'bundleInit' -A6 openddil-helm/openddil-demo/templates/*.yaml | grep 'src'
grep -rn 'asterix_ingestor\|dds_ingestor\|fleet_simulator\|ltamds_simulator\|relay_agent\|OutboxRelay\|edge_restate_detector' \
  openddil-helm/openddil-demo openddil-demo/docker-compose*.yml
```

The first grep returns 48 lines. 34 are producer construction sites: the 33 table rows, with row 10 appearing twice
(`HqProducer(` at its call site and `AIOKafkaProducer(` at the construction). The other 14 are not producers: 9 connect
`input:` blocks (`connect-egress.yaml:23`, `openddil-customer-connect.yaml:23`, `redpanda-connect-edge-01/02/03.yaml`,
`redpanda-connect.yaml`, regional-stack `redpanda-connect.yaml:26`, helm `_helpers.tpl:1109` and `:1262`), 4
config-schema `kafka:` keys (`config.py`, `config.yaml` in sensor-ingest and tactical-agents), and the console config at
`openddil-regional-stack/docker-compose.yml:96`.
