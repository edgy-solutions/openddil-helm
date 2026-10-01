# Runbook note — a Redpanda *cluster* property in the chart does not reach a running cluster

**Status:** open. The chart edit shipped; the mechanism that would make it take
effect on an existing cluster did not, because there isn't one.

## The claim the chart makes, and what is actually true

`infrastructure.yaml` passes cluster properties on the broker command line:

    redpanda start --set redpanda.auto_create_topics_enabled=false

Read as a chart diff, that looks like the setting is now deployed. It is not.
**`--set` seeds cluster properties only when the cluster first forms.** After
that the values live in the controller log, and a broker starting with a
different `--set` adopts the stored value and ignores the flag. Rolling every
broker changes nothing.

So a chart that carries this line, deployed to a cluster that already exists,
produces an installation where the repository says the property is off and all
brokers have it on. That is worse than not shipping it: the discrepancy is
invisible from the chart, and the next person to ask "is auto-create off?"
answers from the template rather than the cluster.

Measured on the lab, 2026-09-28, after the chart change deployed and all five
brokers rolled Ready: **five of five still read `true`.**

## What actually applies it

    rpk cluster config set auto_create_topics_enabled false

Once, against one broker — it is a *cluster* property, so it propagates through
the controller log to all of them. Read it back **per broker**, not once:

    rpk -X admin.hosts=localhost:9644 cluster config get auto_create_topics_enabled

**Corrected 2026-10-01: the property name has no `redpanda.` prefix here.** The prefix belongs
only to `redpanda start --set`. As first written, both commands above used it, and the Admin API
answers that with `Bad Request, Unknown property {redpanda.auto_create_topics_enabled}` (rpk
v26.1.7, HQ broker, measured). The chart's hook (`scripts/redpanda-auto-create-off.sh`) and the
pre-deploy gate (`scripts/check-cluster-config.sh`) already use the unprefixed name, so neither is
affected; only someone copying these lines by hand was.

## Two things that will waste your time

**The admin API is on 9644 on every broker, including HQ.** The HQ container
declares a port named `admin` as 19644, but the process listens on the default.
A read-back against 19644 comes back `connection refused`, which reads as a dead
broker rather than a wrong port.

*Refined 2026-10-01:* this holds from **inside** a broker pod (`localhost`). Reached through
its Service from another pod, HQ answers on **19644** (the Service maps 19644 to the process's
9644) and does not expose 9644 at all. So both numbers are right, each for its own path.
`check-cluster-config.sh` reads each broker's admin port from that broker's own Service, so it
never has to pick one.

**Do not verify this with `rpk topic consume` or `rpk topic produce`.** Both
return `UNKNOWN_TOPIC_OR_PARTITION` and create nothing **whether the property is
on or off**, because rpk's client never asks for auto-creation — so the probe
returns the passing answer in both states and proves nothing. This was caught by
setting the property deliberately back to `true` on one broker and watching the
probe still "pass". A raw Kafka `MetadataRequest` for a missing topic is the
detector that actually distinguishes the two; with the property on, the ask
alone creates the topic.

Related: a produce to a missing topic under auto-create-off does **not** fail
with a clean error. It hangs and retries silently.

## Why this is not just fixed here

Making the chart apply it would mean a Job or hook that runs `rpk cluster config
set` after the brokers are up — which is a new piece of deployment machinery
that can fail, run at the wrong time, or fight a value an operator set by hand.
That is a design decision, not a cleanup, so it is written down rather than
guessed at. Until it is made, **a cluster property in this chart is a statement
of intent for a NEW cluster, and an operator step for an existing one.**
