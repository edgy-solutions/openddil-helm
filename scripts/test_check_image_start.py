"""Tests for check-image-start.py, run against a fake docker and a fake helm.

The fakes are small scripts on PATH. They log their argv (one JSON line per
call) and print canned output; each test steers them through env vars:

  FAKE_HELM_FIXTURE   render fixture helm prints for `template`
  FAKE_HELM_EXIT      non-zero makes helm fail
  FAKE_DOCKER_SPEC    JSON: {"pull_fail": [substr], "init": {image-substr: {exit, log}},
                             "main": {image-substr: {exit, log}}}
A main container with no entry stays running.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "check-image-start.py"
BASIC = HERE / "fixtures" / "image-start" / "render-basic.yaml"
PH = "start-check-placeholder"

FAKE_HELM = r'''
import json, os, sys
log = os.environ.get("FAKE_HELM_LOG")
if log:
    open(log, "a").write(json.dumps(sys.argv[1:]) + "\n")
if int(os.environ.get("FAKE_HELM_EXIT", "0")):
    sys.stderr.write("Error: fake render failure\n")
    sys.exit(int(os.environ["FAKE_HELM_EXIT"]))
sys.stdout.write(open(os.environ["FAKE_HELM_FIXTURE"], encoding="utf-8").read())
'''

FAKE_DOCKER = r'''
import json, os, sys
argv = sys.argv[1:]
spec = json.loads(os.environ.get("FAKE_DOCKER_SPEC", "{}"))
state = os.environ["FAKE_DOCKER_STATE"]
entry = {"argv": argv}


def label():
    for i, a in enumerate(argv):
        if a == "--label" and argv[i + 1].startswith("startcheck.image="):
            return argv[i + 1].split("=", 1)[1]
    return ""


def pick(table, image):
    for k, v in (spec.get(table) or {}).items():
        if k in image:
            return v
    return {}


def snapshot():
    out = {}
    for i, a in enumerate(argv):
        if a == "-v":
            spec_ = argv[i + 1]
            if spec_.endswith(":ro"):
                spec_ = spec_[:-3]
            host, dest = spec_.rsplit(":", 1)
            if os.path.isdir(host):
                files = {}
                for root, _, names in os.walk(host):
                    for n in names:
                        p = os.path.join(root, n)
                        files[os.path.relpath(p, host).replace(os.sep, "/")] = open(p, encoding="utf-8").read()
                out[dest] = {"files": files}
            elif os.path.isfile(host):
                out[dest] = {"file": open(host, encoding="utf-8").read()}
    return out


cmd = argv[0]
rc = 0
if cmd == "pull":
    if any(s in argv[1] for s in spec.get("pull_fail", [])):
        print("Error: manifest unknown")
        rc = 1
elif cmd == "image":
    print(argv[-1].split(":")[0].split("@")[0] + "@sha256:fakefakefake")
elif cmd == "run":
    img = label()
    if "-d" in argv:
        s = pick("main", img)
        json.dump({"exit": s.get("exit"), "log": s.get("log", "")},
                  open(os.path.join(state, argv[argv.index("--name") + 1]), "w"))
        print("fakecontainerid")
    else:
        s = pick("init", img)
        if s.get("log"):
            print(s["log"])
        rc = s.get("exit", 0)
    entry["mounts"] = snapshot()
elif cmd == "inspect":
    st = json.load(open(os.path.join(state, argv[-1])))
    print("running 0" if st["exit"] is None else "exited %d" % st["exit"])
elif cmd == "logs":
    print(json.load(open(os.path.join(state, argv[-1])))["log"])
open(os.environ["FAKE_DOCKER_LOG"], "a").write(json.dumps(entry) + "\n")
sys.exit(rc)
'''


@pytest.fixture
def env(tmp_path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, body in (("helm", FAKE_HELM), ("docker", FAKE_DOCKER)):
        py = tmp_path / ("fake_%s.py" % name)
        py.write_text(body, encoding="utf-8")
        if os.name == "nt":
            (bindir / (name + ".cmd")).write_text('@"%s" "%s" %%*\r\n' % (sys.executable, py), encoding="utf-8")
        else:
            sh = bindir / name
            sh.write_text('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (sys.executable, py), encoding="utf-8")
            sh.chmod(0o755)
    (tmp_path / "state").mkdir()
    (tmp_path / "work").mkdir()
    e = dict(os.environ)
    e["PATH"] = str(bindir) + os.pathsep + e["PATH"]
    e["FAKE_HELM_FIXTURE"] = str(BASIC)
    e["FAKE_HELM_LOG"] = str(tmp_path / "helm.log")
    e["FAKE_DOCKER_LOG"] = str(tmp_path / "docker.log")
    e["FAKE_DOCKER_STATE"] = str(tmp_path / "state")
    e.pop("FAKE_DOCKER_SPEC", None)
    e["_WORK"] = str(tmp_path / "work")
    return e


def run(env, *args, spec=None, **extra):
    env = dict(env)
    if spec is not None:
        env["FAKE_DOCKER_SPEC"] = json.dumps(spec)
    env.update(extra)
    work = env["_WORK"]
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--chart", "chart", "-f", "v.yaml", "--wait", "0"] + list(args),
        env=env, cwd=work, capture_output=True, text=True)


def docker_calls(env):
    log = Path(env["FAKE_DOCKER_LOG"])
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines()]


def main_run(env, ref):
    for c in docker_calls(env):
        a = c["argv"]
        if a[0] == "run" and "-d" in a and ("startcheck.image=%s" % ref) in a:
            return c
    raise AssertionError("no detached run for %s" % ref)


def env_of(call):
    a = call["argv"]
    return {x.split("=", 1)[0]: x.split("=", 1)[1] for i, x in enumerate(a) if i and a[i - 1] == "-e"}


def verdicts(out):
    res = {}
    for line in out.splitlines():
        cells = [c.strip() for c in line.split(" | ")]
        if len(cells) == 4 and cells[0].count("/") == 2:
            res[cells[0]] = cells
    return res


FAUST = "ghcr.io/edgy-solutions/openddil/faust-edge:latest"
BUNDLE = "ghcr.io/edgy-solutions/openddil/runtime-bundle:latest"


def test_selection_skips_third_party_only_pods(env):
    p = run(env)
    assert p.returncode == 0, p.stdout + p.stderr
    assert set(verdicts(p.stdout)) == {"Deployment/web/loader", "Deployment/web/app", "StatefulSet/ui/frontend"}
    assert "Deployment/web/proxy nginx:1.27" in p.stdout        # skip is listed
    assert "Deployment/thirdparty/cache redis:7" in p.stdout
    assert "Job" not in p.stdout and "hook" not in p.stdout    # Jobs are out of scope
    assert "units=3 pass=3 deps=0 allowed=0 fail=0" in p.stdout


def test_env_resolution(env):
    run(env)
    call = main_run(env, FAUST)
    e = env_of(call)
    assert e["LITERAL"] == "plain"
    assert e["COMBINED"] == "pre-plain-hello-post"   # $(VAR) over envFrom and env
    assert e["FROM_CM"] == "hello"
    assert e["FROM_SECRET"] == PH
    assert e["POD_NAME"] == "web-start-check"
    assert e["POD_NS"] == "default"
    assert e["POD_IP"] == "127.0.0.1"
    assert e["NODE"] == "start-check"
    assert e["CPU"] == "1"                            # no value set: the fixture container has no resources
    assert e["GREETING"] == "hello"                   # envFrom configMapRef
    assert "token" not in e                           # envFrom secretRef, Secret not in the render
    a = call["argv"]
    assert a[a.index("--entrypoint") + 1] == "python"
    assert a[a.index(FAUST) + 1:] == ["-m", "runner", "--name=plain", "--cost=$5"]
    assert a[a.index("--user") + 1] == "2000:3000"
    assert a[a.index("-w") + 1] == "/srv"
    assert "--read-only" in a and a[a.index("--network") + 1] == "none"


def test_configmap_items_and_subpath_files(env):
    run(env)
    m = main_run(env, FAUST)["mounts"]
    assert m["/etc/app"]["files"] == {"sub/conf.yaml": "key: value\n"}
    assert m["/etc/other.txt"]["file"] == "other-body"
    init = next(c for c in docker_calls(env) if c["argv"][0] == "run" and "-d" not in c["argv"])
    assert init["argv"][init["argv"].index("--user") + 1] == "1000"   # pod-level user


def test_secret_files_hold_only_the_placeholder(env):
    run(env)
    files = main_run(env, FAUST)["mounts"]["/etc/secret"]["files"]
    assert set(files) == {"token", "nested/password"}
    assert set(files.values()) == {PH}


def test_override_replaces_only_the_named_image(env):
    ref = "ghcr.io/edgy-solutions/openddil/faust-edge@sha256:" + "ab" * 32
    p = run(env, "--override", "faust-edge=" + ref)
    assert p.returncode == 0, p.stdout
    v = verdicts(p.stdout)
    assert v["Deployment/web/app"][1] == ref
    assert v["Deployment/web/loader"][1] == BUNDLE
    assert v["StatefulSet/ui/frontend"][1] == "ghcr.io/edgy-solutions/openddil/frontend:latest"
    pulls = [c["argv"][1] for c in docker_calls(env) if c["argv"][0] == "pull"]
    assert FAUST not in pulls and ref in pulls and BUNDLE in pulls


def test_override_can_name_the_bundle_and_unknown_name_is_bad_input(env):
    p = run(env, "--override", "runtime-bundle=example.invalid/b:1")
    assert verdicts(p.stdout)["Deployment/web/loader"][1] == "example.invalid/b:1"
    assert run(env, "--override", "nosuch=example.invalid/b:1").returncode == 2
    assert run(env, "--override", "faust-edge").returncode == 2


def test_values_extra_follows_values_in_helm_argv(env):
    run(env, "--values-extra", "pins1.yaml", "--values-extra", "pins2.yaml")
    argv = json.loads(Path(env["FAKE_HELM_LOG"]).read_text().splitlines()[0])
    assert argv[:3] == ["template", "t", "chart"]
    assert [argv[i + 1] for i, a in enumerate(argv) if a == "-f"] == ["v.yaml", "pins1.yaml", "pins2.yaml"]


EXPECT = """allowed:
  - {image: faust-edge, container: app, exit: 1, log: "refuses legacy", reason: known and tracked}
"""


def _expect(env, text=EXPECT):
    f = Path(env["_WORK"]) / "expect.yaml"
    f.write_text(text, encoding="utf-8")
    return str(f)


def test_expect_allows_only_on_image_container_exit_and_log(env):
    exp = _expect(env)
    spec = {"main": {"faust-edge": {"exit": 1, "log": "boot\nrunner refuses legacy env"}}}
    p = run(env, "--expect", exp, spec=spec)
    assert p.returncode == 0, p.stdout
    assert verdicts(p.stdout)["Deployment/web/app"][3] == "ALLOWED known and tracked"
    assert "units=3 pass=2 deps=0 allowed=1 fail=0" in p.stdout
    # same exit, different log: stays red
    spec["main"]["faust-edge"]["log"] = "Traceback: something else"
    p = run(env, "--expect", exp, spec=spec)
    assert p.returncode == 1
    assert verdicts(p.stdout)["Deployment/web/app"][3] == "FAIL exit=1"
    assert "Traceback: something else" in p.stdout
    # same log, different exit code: stays red
    spec["main"]["faust-edge"] = {"exit": 2, "log": "refuses legacy"}
    assert run(env, "--expect", exp, spec=spec).returncode == 1
    # different container name: stays red
    other = _expect(env, EXPECT.replace("container: app", "container: other"))
    spec["main"]["faust-edge"] = {"exit": 1, "log": "refuses legacy"}
    assert run(env, "--expect", other, spec=spec).returncode == 1


def test_init_container_failure_is_init_failed(env):
    p = run(env, spec={"init": {"runtime-bundle": {"exit": 3, "log": "cp: cannot stat"}}})
    assert p.returncode == 1
    v = verdicts(p.stdout)
    assert v["Deployment/web/loader"][3].startswith("FAIL init-failed")
    assert v["Deployment/web/app"][3] == "FAIL init-failed"
    assert not any(c["argv"][0] == "run" and "-d" in c["argv"] and "faust-edge" in " ".join(c["argv"])
                   for c in docker_calls(env))
    assert "cp: cannot stat" in p.stdout
    assert "units=3 pass=1 deps=0 allowed=0 fail=2" in p.stdout


def test_pull_failure(env):
    p = run(env, spec={"pull_fail": ["frontend"]})
    assert p.returncode == 1
    assert verdicts(p.stdout)["StatefulSet/ui/frontend"][3] == "FAIL pull"


def test_plan_makes_no_docker_call_and_writes_no_file(env):
    work = Path(env["_WORK"])
    p = run(env, "--plan", "--summary", str(work / "summary.md"))
    assert p.returncode == 0, p.stderr
    assert not Path(env["FAKE_DOCKER_LOG"]).exists()
    assert list(work.iterdir()) == []
    assert "Deployment/web/app" in p.stdout and "/etc/app" in p.stdout
    assert "LITERAL" in p.stdout and "COMBINED" in p.stdout     # names are listed
    assert "pre-plain" not in p.stdout and PH not in p.stdout   # values are not


def test_render_failure_exits_2(env):
    p = run(env, FAKE_HELM_EXIT="1")
    assert p.returncode == 2
    assert not Path(env["FAKE_DOCKER_LOG"]).exists()


def test_summary_line_counts_and_markdown(env):
    work = Path(env["_WORK"])
    spec = {"main": {"faust-edge": {"exit": 1, "log": "boom"}, "frontend": {"exit": 0, "log": ""}}}
    p = run(env, "--summary", str(work / "s.md"), spec=spec)
    assert p.returncode == 1
    assert p.stdout.rstrip().endswith("image-start: units=3 pass=2 deps=0 allowed=0 fail=1")
    md = (work / "s.md").read_text()
    assert "| unit | image ref | digest | verdict |" in md
    assert "units=3 pass=2 deps=0 allowed=0 fail=1" in md
    assert "sha256:fakefakefake" in md


def test_cleanup_removes_containers_and_volumes(env):
    run(env)
    calls = [c["argv"] for c in docker_calls(env)]
    created = [a[2] for a in calls if a[:2] == ["volume", "create"]]
    removed = [a[-1] for a in calls if a[:3] == ["volume", "rm", "-f"]]
    assert created and set(created) == set(removed)
    ran = [a[a.index("--name") + 1] for a in calls if a[0] == "run"]
    gone = [a[-1] for a in calls if a[:2] == ["rm", "-f"]]
    assert set(ran) <= set(gone)


# --------------------------------------------------------------------------
# DEPS classification
# --------------------------------------------------------------------------

_RD = ("%3|1795242874.540|FAIL|rdkafka#producer-1| [thrd:t-redpanda-hq:19092/bootstrap]: "
       "t-redpanda-hq:19092/bootstrap: Failed to resolve 't-redpanda-hq:19092': "
       "Temporary failure in name resolution")
_GATE_ERR = ('2026-11-21 06:34:35,478 ERROR [egress] STARTUP_REFUSED unreachable broker: '
             'KafkaError{code=_TRANSPORT,val=-195,str="Failed to get metadata: Local: Broker transport failure"}')
LOG_GATE = "\n".join([_RD, _RD, _GATE_ERR]) + "\n"
LOG_PANE = ("2026-11-21 06:34:30,000 INFO [pane-api] store connection: postgres://store:5432/db\n"
            "2026-11-21 06:34:31,000 ERROR [pane-api] STARTUP_REFUSED unreachable postgres: "
            "[Errno -3] Temporary failure in name resolution\n")
_SIM_EXC = ("aiokafka.errors.KafkaConnectionError: KafkaConnectionError: Unable to bootstrap from "
            "[('t-redpanda-hq', 19092, <AddressFamily.AF_UNSPEC: 0>)]")
LOG_SIM = ("Traceback (most recent call last):\n"
           '  File "/app/sim.py", line 10, in main\n'
           "    await producer.start()\n"
           + _SIM_EXC + "\n"
           "2026-11-21 06:34:46,669 ERROR [asyncio] Unclosed AIOKafkaProducer\n"
           "producer: <aiokafka.producer.producer.AIOKafkaProducer object at 0x7f>\n")
_ASM_EXC = ('cimpl.KafkaException: KafkaError{code=_INVALID_ARG,val=-186,'
            'str="Failed to set subscription: Local: Invalid argument or configuration"}')
LOG_ASM = (_RD + "\n" + _RD + "\nTraceback (most recent call last):\n"
           '  File "/app/asm.py", line 5, in main\n    c.subscribe(t)\n' + _ASM_EXC + "\n")
_REFUSAL = ("algorithm_runtime.runner.StartupRefusal: ALGORITHMS_ENABLED is unset: "
            "name the units to run, e.g. ALGORITHMS_ENABLED=wear,thermal")
LOG_FAUST = ("Traceback (most recent call last):\n"
             '  File "/app/runner.py", line 9, in run\n    raise StartupRefusal\n' + _REFUSAL + "\n")


def _load():
    import importlib.util
    spec = importlib.util.spec_from_file_location("check_image_start", SCRIPT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def test_classify_exit_dependency_stops():
    m = _load()
    assert m.classify_exit(LOG_GATE) == _GATE_ERR
    assert "unreachable postgres" in m.classify_exit(LOG_PANE)
    assert m.classify_exit(LOG_SIM) == _SIM_EXC


def test_classify_exit_config_refusals_and_noise_are_none():
    m = _load()
    assert m.classify_exit(LOG_ASM) is None
    assert m.classify_exit(LOG_FAUST) is None
    assert m.classify_exit("2026-11-21 INFO [x] starting\n2026-11-21 INFO [x] ready\n") is None


def test_dependency_exit_is_deps_and_refusal_is_fail(env):
    spec = {"main": {"faust-edge": {"exit": 1, "log": LOG_GATE}}}
    p = run(env, spec=spec)
    assert p.returncode == 0, p.stdout
    assert verdicts(p.stdout)["Deployment/web/app"][3] == "DEPS exit=1"
    assert "units=3 pass=2 deps=1 allowed=0 fail=0" in p.stdout
    assert "--- Deployment/web/app: DEPS exit=1: " in p.stdout
    spec = {"main": {"faust-edge": {"exit": 1, "log": LOG_FAUST}}}
    p = run(env, spec=spec)
    assert p.returncode == 1
    assert verdicts(p.stdout)["Deployment/web/app"][3] == "FAIL exit=1"
    assert "  first error: " + _REFUSAL in p.stdout
    assert "units=3 pass=2 deps=0 allowed=0 fail=1" in p.stdout


@pytest.mark.parametrize("resource,value,divisor,expected", [
    ("limits.memory", "512Mi", "1Mi", "512"),
    ("limits.cpu", "500m", "1m", "500"),
    ("limits.cpu", "500m", None, "1"),
    ("limits.memory", "1Gi", "1Mi", "1024"),
    ("limits.memory", "100M", "1Mi", "96"),
    ("requests.memory", "256Mi", "1Mi", "256"),
    ("limits.cpu", "2", None, "2"),
])
def test_resource_field_ref_resolves_like_kubernetes(resource, value, divisor, expected):
    m = _load()
    kind, _, res = resource.partition(".")
    c = {"name": "app", "resources": {kind: {res: value}}}
    ref = {"resource": resource}
    if divisor:
        ref["divisor"] = divisor
    assert m.resource_field_value(ref, c, {"containers": [c]}) == expected


def test_resource_field_ref_names_another_container_or_refuses_unknown():
    m = _load()
    a = {"name": "app", "resources": {"limits": {"memory": "64Mi"}}}
    b = {"name": "side", "resources": {"limits": {"memory": "128Mi"}}}
    pod = {"containers": [a, b]}
    ref = {"resource": "limits.memory", "divisor": "1Mi", "containerName": "side"}
    assert m.resource_field_value(ref, a, pod) == "128"
    with pytest.raises(m.ConfigError):
        m.resource_field_value(dict(ref, containerName="nope"), a, pod)
