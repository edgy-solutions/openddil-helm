<#
.SYNOPSIS
  Mirror every container image the openddil-demo chart references from its
  upstream registry (ghcr.io / Docker Hub / docker.redpanda.com) into a
  single Artifactory (or any other) registry under one base path.

.DESCRIPTION
  Two copy engines, selectable with -Method:

    buildx  (DEFAULT) -- uses 'docker buildx imagetools', which ships with
            Docker Desktop. No extra tool to install or get approved.
    crane             -- uses 'crane' (github.com/google/go-containerregistry).
            Slightly simpler internally, but requires installing crane.

  WHY this is not just 'docker pull / tag / push':
  Every openddil-* GHA workflow uses docker/build-push-action, which adds
  a provenance attestation as an extra manifest entry with platform
  unknown/unknown. Docker Desktop with the containerd image store keeps
  that full OCI index locally even after 'docker pull --platform', and a
  subsequent 'docker push' sends the index, which Artifactory rejects:
    image with reference X was found but does not provide any platform

  Both engines here avoid that:
    buildx -- inspects the source index, resolves the single
              <Platform> child manifest by digest, and copies ONLY that
              child. The attestation entry is never referenced.
    crane  -- streams blobs registry-to-registry and honours --platform
              to copy exactly one architecture.

  Auth: both engines reuse Docker's credential store
  (~/.docker/config.json), so the standard logins set up credentials:
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

.PARAMETER Method
  Copy engine: 'buildx' (default, no install) or 'crane'.

.PARAMETER Platform
  Architecture to copy (default linux/amd64). arm64 builds are not yet
  published by the openddil-* GHA workflows; until those add multi-arch,
  linux/arm64 will fail at the upstream resolve step.

.PARAMETER DryRun
  Print the commands without executing.

.EXAMPLE
  .\mirror-to-artifactory.ps1 -RepoBase cbm-containers-dev-and.artifactory-and.rmd.ray.com

.EXAMPLE
  .\mirror-to-artifactory.ps1 -RepoBase artifactory.mycorp.com/docker-openddil -Method crane

.EXAMPLE
  .\mirror-to-artifactory.ps1 -RepoBase artifactory.mycorp.com/docker-openddil -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$RepoBase,

    [ValidateSet('buildx','crane')]
    [string]$Method = 'buildx',

    [string]$Platform = 'linux/amd64',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoBase = $RepoBase.TrimEnd('/')

# -----------------------------------------------------------------------
# Prereq check for the selected engine.
# -----------------------------------------------------------------------
if ($Method -eq 'crane') {
    if (-not (Get-Command crane -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: -Method crane selected but 'crane' is not on PATH." -ForegroundColor Red
        Write-Host "Install crane, or use the default -Method buildx (no install)." -ForegroundColor Yellow
        exit 1
    }
} else {
    # buildx: confirm 'docker buildx' responds.
    & docker buildx version *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: 'docker buildx' is not available." -ForegroundColor Red
        Write-Host "buildx ships with Docker Desktop; update Docker Desktop if missing." -ForegroundColor Yellow
        exit 1
    }
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

# -----------------------------------------------------------------------
# Strip the :tag suffix from an image reference, leaving the repository.
# The tag is the part after the LAST colon that is not followed by a
# slash. Registry ports (registry:5000/...) are not matched because the
# port colon is followed by '/'. None of the inventory uses a digest.
# -----------------------------------------------------------------------
function Get-RepoOnly {
    param([string]$Ref)
    return ($Ref -replace ':[^:/]+$', '')
}

# -----------------------------------------------------------------------
# buildx engine: inspect the source, resolve the <Platform> child by
# digest, copy ONLY that child via 'imagetools create'. Drops the
# provenance attestation (it is a different, unreferenced child).
# -----------------------------------------------------------------------
function Copy-WithBuildx {
    param([string]$Src, [string]$Dst, [string]$Platform)

    $plat  = $Platform -split '/'
    $os    = $plat[0]
    $arch  = $plat[1]

    $rawLines = & docker buildx imagetools inspect $Src --raw 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "buildx inspect failed for $Src (image missing / not logged in?)"
    }
    $manifest = ($rawLines -join "`n") | ConvertFrom-Json

    if ($manifest.manifests) {
        # Multi-entry OCI index. Find the child matching the platform.
        $child = $manifest.manifests | Where-Object {
            $_.platform.os -eq $os -and $_.platform.architecture -eq $arch
        } | Select-Object -First 1
        if (-not $child) {
            throw "no $Platform manifest in $Src (arm64 not published yet?)"
        }
        $srcByDigest = (Get-RepoOnly $Src) + '@' + $child.digest
        if ($DryRun) {
            Write-Host "[dry-run] docker buildx imagetools create --tag $Dst $srcByDigest" -ForegroundColor Yellow
        } else {
            & docker buildx imagetools create --tag $Dst $srcByDigest
            if ($LASTEXITCODE -ne 0) { throw "buildx create failed for $Dst" }
        }
    } else {
        # Plain single-arch manifest; copy as-is.
        if ($DryRun) {
            Write-Host "[dry-run] docker buildx imagetools create --tag $Dst $Src" -ForegroundColor Yellow
        } else {
            & docker buildx imagetools create --tag $Dst $Src
            if ($LASTEXITCODE -ne 0) { throw "buildx create failed for $Dst" }
        }
    }
}

# -----------------------------------------------------------------------
# crane engine: one-shot registry-to-registry copy with --platform.
# -----------------------------------------------------------------------
function Copy-WithCrane {
    param([string]$Src, [string]$Dst, [string]$Platform)
    if ($DryRun) {
        Write-Host "[dry-run] crane copy --platform $Platform $Src $Dst" -ForegroundColor Yellow
    } else {
        & crane copy --platform $Platform $Src $Dst
        if ($LASTEXITCODE -ne 0) { throw "crane copy failed for $Dst" }
    }
}

Write-Host "Mirroring $($Images.Count) images to $RepoBase" -ForegroundColor Cyan
Write-Host "Method: $Method   Platform: $Platform" -ForegroundColor Cyan
Write-Host ""

$failed = @()
foreach ($img in $Images) {
    $src = $img.src
    $dst = "$RepoBase/$($img.dst)"

    Write-Host "==> $src" -ForegroundColor Green
    Write-Host "    -> $dst"

    try {
        if ($Method -eq 'crane') {
            Copy-WithCrane  -Src $src -Dst $dst -Platform $Platform
        } else {
            Copy-WithBuildx -Src $src -Dst $dst -Platform $Platform
        }
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
Write-Host "Next step: substitute <ARTIFACTORY> in values-artifactory.yaml"
Write-Host "with ${RepoBase}, then helm install. PowerShell substitution:"
Write-Host ""
$sub = '(Get-Content values-artifactory.yaml) -replace ''<ARTIFACTORY>'', ''' + $RepoBase + ''' | Set-Content values-mycorp.yaml'
Write-Host "  $sub" -ForegroundColor White
Write-Host "  helm install openddil oci://$RepoBase/edgy-solutions/openddil/charts/openddil-demo ``" -ForegroundColor White
Write-Host "    --version 0.1.4 ``" -ForegroundColor White
Write-Host "    --namespace openddil --create-namespace ``" -ForegroundColor White
Write-Host "    -f values-mycorp.yaml" -ForegroundColor White
