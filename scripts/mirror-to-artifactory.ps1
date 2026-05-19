<#
.SYNOPSIS
  Mirror every container image the openddil-demo chart references from its
  upstream registry (ghcr.io / Docker Hub / docker.redpanda.com) into a
  single Artifactory (or any other) registry under one base path.

.DESCRIPTION
  Uses 'crane copy' (github.com/google/go-containerregistry) for
  registry-to-registry image copy. crane is REQUIRED -- see the prereq
  check below.

  WHY crane, not docker pull/tag/push:
  Every openddil-* GHA workflow uses docker/build-push-action, which adds
  a provenance attestation as an extra manifest entry with platform
  unknown/unknown. Docker Desktop with the containerd image store keeps
  that full OCI index locally even after 'docker pull --platform', and a
  subsequent 'docker push' sends the index -- which Artifactory rejects:
    image with reference X was found but does not provide any platform
  crane streams blobs registry-to-registry without ever touching the
  local Docker store, and --platform makes it copy EXACTLY ONE
  architecture's manifest. No attestation passenger, no containerd
  weirdness.

  Auth: crane reads Docker's credential store (~/.docker/config.json),
  so the standard logins still set up credentials:
    docker login ghcr.io
    docker login artifactory.mycorp.com

  Destination naming: registry host stripped, rest of the path preserved
  under -RepoBase:
    ghcr.io/edgy-solutions/openddil/frontend:latest
      -> <RepoBase>/edgy-solutions/openddil/frontend:latest
    docker.redpanda.com/redpandadata/redpanda:v26.1.7
      -> <RepoBase>/redpandadata/redpanda:v26.1.7
    postgres:15  (= docker.io/library/postgres:15)
      -> <RepoBase>/library/postgres:15

.PARAMETER RepoBase
  Destination registry + path prefix. Examples:
    artifactory.mycorp.com/docker-openddil
    cbm-containers-dev-and.artifactory-and.rmd.ray.com
  Trailing slashes get trimmed.

.PARAMETER Platform
  Architecture to copy (default linux/amd64). arm64 builds are not yet
  published by the openddil-* GHA workflows; until those add multi-arch,
  linux/arm64 will fail at the upstream resolve step.

.PARAMETER DryRun
  Print the crane commands without executing.

.EXAMPLE
  .\mirror-to-artifactory.ps1 -RepoBase cbm-containers-dev-and.artifactory-and.rmd.ray.com

.EXAMPLE
  .\mirror-to-artifactory.ps1 -RepoBase artifactory.mycorp.com/docker-openddil -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepoBase,

    [string]$Platform = 'linux/amd64',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoBase = $RepoBase.TrimEnd('/')

# -----------------------------------------------------------------------
# Prereq: crane must be on PATH.
# -----------------------------------------------------------------------
$craneCmd = Get-Command crane -ErrorAction SilentlyContinue
if (-not $craneCmd) {
    Write-Host "ERROR: 'crane' not found on PATH." -ForegroundColor Red
    Write-Host ""
    Write-Host "crane is a single Go binary (~15 MB). Install one of these ways:" -ForegroundColor Yellow
    Write-Host "  scoop install crane" -ForegroundColor White
    Write-Host "  go install github.com/google/go-containerregistry/cmd/crane@latest" -ForegroundColor White
    Write-Host "  # or download crane from the GitHub releases page:" -ForegroundColor White
    Write-Host "  #   github.com/google/go-containerregistry/releases" -ForegroundColor White
    Write-Host "  #   (extract crane.exe to a directory on PATH)" -ForegroundColor White
    Write-Host ""
    Write-Host "crane reuses your existing 'docker login' credentials." -ForegroundColor Yellow
    Write-Host "No separate auth step is needed once it is installed." -ForegroundColor Yellow
    exit 1
}

# -----------------------------------------------------------------------
# Image inventory: every image the openddil-demo chart references.
#   1. OpenDDIL-owned (ghcr.io/edgy-solutions/openddil/*) at :latest,
#      published by the per-service GHA workflows.
#   2. Third-party services, semver-pinned (synced with values.yaml).
#   3. Utility images: atlas / alpine / curl, semver-pinned.
# Keep the src tags synced with openddil-demo/values.yaml.
# -----------------------------------------------------------------------
$Images = @(
    # OpenDDIL-owned (9)
    @{ src='ghcr.io/edgy-solutions/openddil/frontend:latest';                 dst='edgy-solutions/openddil/frontend:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/sensor-ingest:latest';            dst='edgy-solutions/openddil/sensor-ingest:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/faust-edge:latest';               dst='edgy-solutions/openddil/faust-edge:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/faust-regional:latest';           dst='edgy-solutions/openddil/faust-regional:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/projector:latest';                dst='edgy-solutions/openddil/projector:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/cm-service:latest';               dst='edgy-solutions/openddil/cm-service:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/logistics-fusion-service:latest'; dst='edgy-solutions/openddil/logistics-fusion-service:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/hub-restate-projector:latest';    dst='edgy-solutions/openddil/hub-restate-projector:latest' },
    @{ src='ghcr.io/edgy-solutions/openddil/runtime-bundle:latest';           dst='edgy-solutions/openddil/runtime-bundle:latest' },

    # Third-party services (semver-pinned, security-review-friendly)
    @{ src='docker.redpanda.com/redpandadata/redpanda:v26.1.7';               dst='redpandadata/redpanda:v26.1.7' },
    @{ src='docker.redpanda.com/redpandadata/connect:4.91.0';                 dst='redpandadata/connect:4.91.0' },
    @{ src='electricsql/electric:1.6.2';                                      dst='electricsql/electric:1.6.2' },
    @{ src='postgres:15';                                                     dst='library/postgres:15' },
    @{ src='restatedev/restate:1.6.2';                                        dst='restatedev/restate:1.6.2' },
    @{ src='ghcr.io/shopify/toxiproxy:2.12.0';                                dst='shopify/toxiproxy:2.12.0' },

    # Utility images
    @{ src='arigaio/atlas:0.32.0';                                            dst='arigaio/atlas:0.32.0' },
    @{ src='alpine:3.20';                                                     dst='library/alpine:3.20' },
    @{ src='curlimages/curl:8.9.1';                                           dst='curlimages/curl:8.9.1' }
)

Write-Host "Mirroring $($Images.Count) images to $RepoBase (platform: $Platform)" -ForegroundColor Cyan
Write-Host "Using crane: $($craneCmd.Source)" -ForegroundColor Cyan
Write-Host ""

$failed = @()
foreach ($img in $Images) {
    $src = $img.src
    $dst = "$RepoBase/$($img.dst)"

    Write-Host "==> $src" -ForegroundColor Green
    Write-Host "    -> $dst"

    # crane copy --platform <p> SRC DST
    #   --platform resolves the source index to ONE architecture and
    #   copies only that manifest, dropping the provenance attestation
    #   entry (platform unknown/unknown) that Artifactory rejects.
    $craneArgs = @('copy', '--platform', $Platform, $src, $dst)

    if ($DryRun) {
        Write-Host "[dry-run] crane $($craneArgs -join ' ')" -ForegroundColor Yellow
    } else {
        & crane @craneArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    FAILED: crane copy exited $LASTEXITCODE" -ForegroundColor Red
            $failed += $src
        }
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
Write-Host "Next step: substitute <ARTIFACTORY> in values-artifactory.yaml"
Write-Host "with ${RepoBase}, then helm install. PowerShell substitution:"
Write-Host ""
$sub = '(Get-Content values-artifactory.yaml) -replace ''<ARTIFACTORY>'', ''' + $RepoBase + ''' | Set-Content values-mycorp.yaml'
Write-Host "  $sub" -ForegroundColor White
Write-Host "  helm install openddil oci://$RepoBase/edgy-solutions/openddil/charts/openddil-demo ``" -ForegroundColor White
Write-Host "    --version 0.1.4 ``" -ForegroundColor White
Write-Host "    --namespace openddil --create-namespace ``" -ForegroundColor White
Write-Host "    -f values-mycorp.yaml" -ForegroundColor White
