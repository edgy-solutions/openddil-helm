"""Print the sensor-ingest Deployment documents of a rendered manifest, byte
for byte, joined by '---'. stdin -> stdout. Used by test_entity_assignment.sh
to diff the sidecars alone, so an unrelated template change cannot mask or
fake a difference. The chart version in the `helm.sh/chart` label is replaced
by VERSION, so a version bump alone does not change the output."""
import re
import sys

text = sys.stdin.buffer.read().decode("utf-8").replace("\r\n", "\n")
docs = re.split(r"(?m)^---\n", text)
keep = [d for d in docs
        if re.search(r"(?m)^kind: Deployment$", d)
        and re.search(r"(?m)^  name: \S+-sensor-ingest-\S+$", d)]
if not keep:
    sys.exit("no sensor-ingest Deployments in the render")
out = "---\n".join(keep)
out = re.sub(r"(?m)^(\s*helm\.sh/chart: \S+?-)\d+\.\d+\.\d+\S*$", r"\1VERSION", out)
sys.stdout.buffer.write(out.encode("utf-8"))
