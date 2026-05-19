<#
.SYNOPSIS
  Mirror every container image the openddil-demo chart references from its
  upstream registry (ghcr.io / Docker Hub / docker.redpanda.com) into a
  single Artifactory (or any other) registry under one base path.

.DESCRIPTION
  Pulls each image from upstream, re-tags it under -RepoBase, and pushes.
  Assumes you are already logged in to BOTH registries:
    docker login ghcr.io
    docker login artifactory.mycorp.com
  (Anonymous pulls from public ghcr.io / Docker Hub work for the upstreams
  too — `docker login ghcr.io` is only needed if you've hit anonymous rate
  limits.)

  Destination naming convention: the registry host is stripped, and the
  rest of the path is preserved under -RepoBase. So:
    ghcr.io/edgy-solutions/openddil/frontend:latest
    -> <RepoBase>/edgy-solutions/openddil/frontend:latest
    docker.redpanda.com/redpandadata/redpanda:latest
    -> <RepoBase>/redpandadata/redpanda:latest
    postgres:15  (= docker.io/library/postgres:15)
    -> <RepoBase>/library/postgres:15

  values-artifactory.yaml (committed alongside this script) reflects this
  convention — every <service>.image.repository points at
  <RepoBase>/<original-path-with-registry-stripped>.

.PARAMETER RepoBase
  Destination registry + path prefix. Examples:
    artifactory.mycorp.com/docker-openddil
    my-registry.internal/openddil-mirror
  Trailing slashes get trimmed.

.PARAMETER DryRun
  Print the docker commands without executing.

.EXAMPLE
  .\mirror-to-artifactory.ps1 -RepoBase artifactory.mycorp.com/docker-openddil

.EXAMPLE
  .\mirror-to-artifactory.ps1 -RepoBase artifactory.mycorp.com/docker-openddil -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepoBase,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoBase = $RepoBase.TrimEnd('/')

# -----------------------------------------------------------------------
# Image inventory — every image the openddil-demo chart pulls.
#
# Three categories surfaced explicitly:
#   1. OpenDDIL-owned (ghcr.io/edgy-solutions/openddil/*) — bumped by the
#      per-service GHA workflows; pinned at :latest here for first cut.
#      Pin to specific versions if your deployment story needs reproducible
#      mirrors.
#   2. Third-party services — Redpanda, Postgres, Electric, Restate,
#      Toxiproxy. Tags taken from values.yaml; bump here when you bump
#      values.
#   3. Template-hardcoded utility images — Atlas (postgres-schema-init
#      Job), Alpine (Job no-op container), curlimages/curl (helm-test
#      pods). NOT currently parameterized via values.yaml. If your
#      deployment forbids pulling these from upstream, you need to mirror
#      them anyway (Atlas + Alpine are critical-path on install; Curl is
#      only needed for `helm test`).
# -----------------------------------------------------------------------
$Images = @(
    # -- OpenDDIL-owned (9) -----------------------------------------------
    # Pinned at :latest pending an explicit version-tagging strategy for
    # OpenDDIL-owned services. Per-image GHA workflows publish :latest on
    # every push to master.
    @{ src='ghcr.io/edgy-solutions/openddil/frontend:latest';                dst='edgy-solutions/openddil/frontend:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/sensor-ingest:latest';           dst='edgy-solutions/openddil/sensor-ingest:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/faust-edge:latest';              dst='edgy-solutions/openddil/faust-edge:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/faust-regional:latest';          dst='edgy-solutions/openddil/faust-regional:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/projector:latest';               dst='edgy-solutions/openddil/projector:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/cm-service:latest';              dst='edgy-solutions/openddil/cm-service:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/logistics-fusion-service:latest'; dst='edgy-solutions/openddil/logistics-fusion-service:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/hub-restate-projector:latest';   dst='edgy-solutions/openddil/hub-restate-projector:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/runtime-bundle:latest';          dst='edgy-solutions/openddil/runtime-bundle:latest' },

    # -- Third-party services (semver-pinned, security-review-friendly) --
    # Versions identified 2026-05-19 by running each binary's --version
    # inside its image; verified that the tag exists upstream via
    # `docker manifest inspect`. Bump these tags when you intentionally
    # roll forward; keep synced with values.yaml.
    @{ src='docker.redpanda.com/redpandadata/redpanda:v26.1.7';               dst='redpandadata/redpanda:v26.1.7' },
    @{ src='docker.redpanda.com/redpandadata/connect:4.91.0';                 dst='redpandadata/connect:4.91.0' },
    @{ src='electricsql/electric:1.6.2';                                      dst='electricsql/electric:1.6.2' },
    @{ src='postgres:15';                                                     dst='library/postgres:15' },
    @{ src='restatedev/restate:1.6.2';                                        dst='restatedev/restate:1.6.2' },
    @{ src='ghcr.io/shopify/toxiproxy:2.12.0';                                dst='shopify/toxiproxy:2.12.0' },

    # -- Utility images --------------------------------------------------
    # arigaio/atlas:latest tracks the canary build line (v1.x-canary as of
    # 2026-05-19). 0.32.0 is the latest stable 0.x release — same migrate-
    # apply surface, security-review-friendly tag.
    @{ src='arigaio/atlas:0.32.0';                                            dst='arigaio/atlas:0.32.0' },
    @{ src='alpine:3.20';                                                     dst='library/alpine:3.20' },
    @{ src='curlimages/curl:8.9.1';                                           dst='curlimages/curl:8.9.1' }
)

function Invoke-Docker {
    # NOTE: param name is $DockerArgs, NOT $Args. $Args is a PowerShell
    # automatic variable (the function's positional args); declaring a
    # param with that name in PS 5.1 causes the value to be lost on the
    # call boundary (verified: dry-run rendered empty `docker` invocations).
    param([string[]]$DockerArgs)
    if ($DryRun) {
        Write-Host "[dry-run] docker $($DockerArgs -join ' ')" -ForegroundColor Yellow
    } else {
        & docker @DockerArgs
        if ($LASTEXITCODE -ne 0) {
            throw "docker $($DockerArgs[0]) failed (exit $LASTEXITCODE)"
        }
    }
}

Write-Host "Mirroring $($Images.Count) images to $RepoBase" -ForegroundColor Cyan
Write-Host ""

$failed = @()
foreach ($img in $Images) {
    $src = $img.src
    $dst = "$RepoBase/$($img.dst)"

    Write-Host "==> $src" -ForegroundColor Green
    Write-Host "    -> $dst"

    try {
        Invoke-Docker @('pull', $src)
        Invoke-Docker @('tag',  $src, $dst)
        Invoke-Docker @('push', $dst)
    } catch {
        Write-Host "    FAILED: $_" -ForegroundColor Red
        $failed += $src
    }
    Write-Host ""
}

if ($failed.Count -gt 0) {
    Write-Host "Failed images:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "All $($Images.Count) images mirrored to $RepoBase" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step: install the chart with values-artifactory.yaml,"
Write-Host "substituting <ARTIFACTORY> in that file with ${RepoBase}:"
Write-Host ""
Write-Host "  (Get-Content values-artifactory.yaml) -replace '<ARTIFACTORY>', '$RepoBase' |" -ForegroundColor White
Write-Host "    Set-Content values-mycorp.yaml" -ForegroundColor White
Write-Host "  helm install openddil oci://$RepoBase/edgy-solutions/openddil/charts/openddil-demo ``" -ForegroundColor White
Write-Host "    --version 0.1.4 ``" -ForegroundColor White
Write-Host "    --namespace openddil --create-namespace ``" -ForegroundColor White
Write-Host "    -f values-mycorp.yaml" -ForegroundColor White
