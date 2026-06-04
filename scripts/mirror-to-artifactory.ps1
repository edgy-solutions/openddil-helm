<#
.SYNOPSIS
  Mirror every container image the openddil-demo chart references from its
  upstream registry (ghcr.io / Docker Hub / docker.redpanda.com) into a
  single Artifactory (or any other) registry under one base path.

  Hash-aware: each image is checked against the destination first. If the
  destination tag already points at the source's desired digest, the
  image is logged as UNCHANGED and no bytes are transferred. Saves
  bandwidth and gives a clear "what changed since last run" report at
  the end (UPDATE / NEW / UNCHANGED counts).

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
# Resolve a reference to the digest we WANT the destination to point at.
# For multi-arch sources, this is the platform-specific child digest (the
# same value Copy-WithBuildx would use as the source-by-digest ref).
# For single-arch sources, it's the manifest's own digest.
#
# Dispatches by $Method (script-scope param) so crane users don't need
# buildx installed too. Returns $null on failure -- caller treats null
# as "can't verify, just mirror."
# -----------------------------------------------------------------------
function Resolve-DesiredDigest {
    param([string]$Ref, [string]$Platform)

    if ($Method -eq 'crane') {
        # crane digest --platform resolves multi-arch indexes to the
        # child digest in one call. For single-arch it returns the
        # manifest's own digest.
        $out = & crane digest --platform $Platform $Ref 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return $out.Trim() }
        return $null
    }

    # buildx path
    $plat  = $Platform -split '/'
    $os    = $plat[0]
    $arch  = $plat[1]

    $rawLines = & docker buildx imagetools inspect $Ref --raw 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $manifest = ($rawLines -join "`n") | ConvertFrom-Json

    if ($manifest.manifests) {
        $child = $manifest.manifests | Where-Object {
            $_.platform.os -eq $os -and $_.platform.architecture -eq $arch
        } | Select-Object -First 1
        if (-not $child) { return $null }
        return $child.digest
    }

    # Single-arch: top-level manifest digest.
    $top = & docker buildx imagetools inspect $Ref --format '{{.Manifest.Digest}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) {
        return $top.Trim()
    }
    return $null
}

# -----------------------------------------------------------------------
# What digest does the destination TAG currently point at? Returns
# $null if the destination doesn't exist (never mirrored) or auth
# fails. Treated by caller the same as "different digest" -- mirror.
# Same crane/buildx dispatch as above.
# -----------------------------------------------------------------------
function Get-DestinationTagDigest {
    param([string]$Dst)

    if ($Method -eq 'crane') {
        $out = & crane digest $Dst 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return $out.Trim() }
        return $null
    }

    $out = & docker buildx imagetools inspect $Dst --format '{{.Manifest.Digest}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) {
        return $out.Trim()
    }
    return $null
}

# -----------------------------------------------------------------------
# buildx engine: inspect the source, resolve the <Platform> child by
# digest, copy ONLY that child via 'imagetools create'. Drops the
# provenance attestation (it is a different, unreferenced child).
# Accepts a pre-resolved $SrcDigest so the caller's hash-skip check
# doesn't need to re-inspect.
# -----------------------------------------------------------------------
function Copy-WithBuildx {
    param([string]$Src, [string]$Dst, [string]$Platform, [string]$SrcDigest)

    if ($SrcDigest) {
        # Caller already resolved the digest. Tag the destination with the
        # exact source-by-digest reference (drops provenance attestation
        # for multi-arch; harmless no-op for single-arch).
        $srcByDigest = (Get-RepoOnly $Src) + '@' + $SrcDigest
        if ($DryRun) {
            Write-Host "[dry-run] docker buildx imagetools create --tag $Dst $srcByDigest" -ForegroundColor Yellow
        } else {
            & docker buildx imagetools create --tag $Dst $srcByDigest
            if ($LASTEXITCODE -ne 0) { throw "buildx create failed for $Dst" }
        }
        return
    }

    # Fallback path -- should not be reached in normal flow because the
    # main loop resolves the digest up-front, but keep for safety in
    # case anyone calls Copy-WithBuildx directly.
    if ($DryRun) {
        Write-Host "[dry-run] docker buildx imagetools create --tag $Dst $Src" -ForegroundColor Yellow
    } else {
        & docker buildx imagetools create --tag $Dst $Src
        if ($LASTEXITCODE -ne 0) { throw "buildx create failed for $Dst" }
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

$failed     = @()
$mirrored   = @()
$unchanged  = @()

foreach ($img in $Images) {
    $src = $img.src
    $dst = "$RepoBase/$($img.dst)"

    Write-Host "==> $src" -ForegroundColor Green
    Write-Host "    -> $dst"

    try {
        # Hash-aware skip: compare source's desired digest to destination's
        # current tag digest. Match -> no bytes transferred, just log.
        # Mismatch (or destination absent) -> mirror.
        $srcDigest = Resolve-DesiredDigest -Ref $src -Platform $Platform
        if (-not $srcDigest) {
            throw "could not resolve source digest for $src (image missing / not logged in?)"
        }
        $dstDigest = Get-DestinationTagDigest -Dst $dst

        if ($dstDigest -eq $srcDigest) {
            Write-Host "    UNCHANGED: destination already at $srcDigest" -ForegroundColor DarkGray
            $unchanged += $src
            Write-Host ""
            continue
        }

        if ($dstDigest) {
            Write-Host "    UPDATE  src=$srcDigest" -ForegroundColor Yellow
            Write-Host "            dst=$dstDigest (will be replaced)" -ForegroundColor Yellow
        } else {
            Write-Host "    NEW     src=$srcDigest (destination tag absent)" -ForegroundColor Yellow
        }

        if ($Method -eq 'crane') {
            Copy-WithCrane  -Src $src -Dst $dst -Platform $Platform
        } else {
            Copy-WithBuildx -Src $src -Dst $dst -Platform $Platform -SrcDigest $srcDigest
        }
        $mirrored += $src
    } catch {
        Write-Host "    FAILED: $_" -ForegroundColor Red
        $failed += $src
    }
    Write-Host ""
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host ("  unchanged : {0,3}" -f $unchanged.Count) -ForegroundColor DarkGray
Write-Host ("  mirrored  : {0,3}" -f $mirrored.Count)  -ForegroundColor Green
$failColor = if ($failed.Count -gt 0) { 'Red' } else { 'DarkGray' }
Write-Host ("  failed    : {0,3}" -f $failed.Count)    -ForegroundColor $failColor
Write-Host ""

if ($mirrored.Count -gt 0) {
    Write-Host "Newly mirrored / updated images:" -ForegroundColor Green
    $mirrored | ForEach-Object { Write-Host "  + $_" -ForegroundColor Green }
    Write-Host ""
}

if ($failed.Count -gt 0) {
    Write-Host "Failed images:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

if ($mirrored.Count -eq 0) {
    Write-Host "All images already up to date at $RepoBase -- no bytes transferred." -ForegroundColor Cyan
} else {
    Write-Host "Mirror complete: $($mirrored.Count) updated, $($unchanged.Count) skipped." -ForegroundColor Cyan
}
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
