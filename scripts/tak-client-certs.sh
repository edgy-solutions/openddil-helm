#!/usr/bin/env bash
# ===========================================================================
# tak-client-certs.sh — mutual-TLS cert bundle + ATAK/WinTAK data package for
# one TAK device, for use with the egress.tak.tls ghostunnel sidecar
# (openddil-demo/templates/egress.yaml).
# ===========================================================================
# Usage:
#   tak-client-certs.sh <out-dir> <server-host-or-ip> <device-cn>
#
# WHAT THIS DOES
#   1. Creates (or reuses, if already present in <out-dir>) a CA keypair.
#   2. Creates a server cert/key signed by that CA, SAN = <server-host-or-ip>
#      (DNS SAN if it parses as a hostname, IP SAN if it parses as an IPv4/
#      IPv6 literal). This is the cert the ghostunnel sidecar presents.
#   3. Creates a client cert/key signed by that CA with CN=<device-cn>. The
#      sidecar's --allow-cn <device-cn> (set via egress.tak.tls.allowedClientCNs)
#      is what actually admits this device; the chart does not read anything
#      else out of this certificate.
#   4. Bundles the client cert/key into <device-cn>.p12, and the CA cert alone
#      into truststore.p12, both password-protected.
#   5. Builds <device-cn>-datapackage.zip: an ATAK/WinTAK data package that
#      imports the client p12, the truststore p12, and a stream preference
#      pointing at <server-host-or-ip>:<port>:ssl.
#   6. Prints (does NOT run) the `kubectl create secret generic` command that
#      loads the CA + server cert/key into the Secret named by
#      egress.tak.tls.secretName.
#
# CRYPTOGRAPHIC OPERATIONS USE OPENSSL ONLY. A genuine ZIP
# container is physically outside what openssl can produce (it has no
# archiving function at all), so step 5's archiving — not any cryptographic
# operation — falls back to the Python standard library's `zipfile` module
# (tries `zip` first if present on PATH, since that's the more common tool;
# falls back to python3/python/py's zipfile otherwise). If neither `zip` nor
# a python interpreter is on PATH, the script fails with a clear message
# rather than silently skipping the data package.
#
# WHY A REFUSAL INSIDE A GIT WORK TREE: this script's whole output is private
# key material for one device. A git work tree is a place things get
# committed, pushed, and mirrored by accident; this script will not write
# private keys there. Point <out-dir> somewhere outside any git work tree
# (e.g. a directory under your home directory, or /tmp on a machine you
# trust).
#
# THE AUDIENCE RULE (see egress.yaml and docs/tak-client-setup.md): admitting
# a CN via --allow-cn admits that device to the full destination audience
# behind this sidecar, not to a subset of it. Revoking access means removing
# the CN from egress.tak.tls.allowedClientCNs and running `helm upgrade` —
# there is no per-message or per-track filtering.
#
# ATAK/WinTAK DATA PACKAGE LAYOUT AND PREFERENCE KEYS BELOW ARE COPIED FROM
# taky 0.10's OWN BUILDER, NOT GUESSED:
#   taky/cli/build_client_cmd.py (taky 0.10 sdist from PyPI):
#     lines 49-58  - package layout: certs/<server-p12-name>, certs/<client
#                    cn>.p12, a preference file, all zipped with a
#                    MANIFEST/manifest.xml at the zip root.
#     lines 99-114 - the exact ATAK preference dict (cot_streams +
#                    com.atakmap.app_preferences keys below).
#     lines 119-136 - the exact manifest Configuration/Contents shape.
#   taky/util/datapackage.py (same sdist):
#     lines 6-47   - build_pref(): <preferences><preference version="1"
#                    name="..."><entry key="..." class="class java.lang.
#                    {Boolean|Integer|String}">value</entry>...
#     lines 50-83  - build_manifest(): <MissionPackageManifest version="2">
#                    with <Configuration><Parameter name=... value=.../></
#                    Configuration><Contents><Content ignore="false"
#                    zipEntry="certs/<name>"/></Contents>.
# ===========================================================================
set -uo pipefail

# On Git-Bash/MSYS, an argument that starts with a single "/" (like
# openssl's "-subj /CN=...") is heuristically treated as a POSIX path and
# silently rewritten to a Windows path. The standard workaround is a
# doubled leading slash ("//CN=..."), which both openssl and real POSIX
# shells accept identically to a single slash, but which MSYS's heuristic
# leaves alone. subj_arg() centralizes that so real file-path arguments
# elsewhere in this script are untouched and still get normal, correct
# POSIX->Windows conversion.
subj_arg() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*) printf '//%s' "$1" ;;
    *) printf '/%s' "$1" ;;
  esac
}

usage() {
  echo "Usage: $0 <out-dir> <server-host-or-ip> <device-cn>" >&2
  echo "  <out-dir>            directory to write certs + data package into" >&2
  echo "                       (reused if it already holds a ca.pem/ca.key)" >&2
  echo "  <server-host-or-ip>  hostname or IP the device will connect to;" >&2
  echo "                       becomes the server cert's SAN and the stream" >&2
  echo "                       address in the generated data package" >&2
  echo "  <device-cn>          CN for the client cert; must match an entry" >&2
  echo "                       in egress.tak.tls.allowedClientCNs" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
OUT_DIR=$1
SERVER_HOST=$2
DEVICE_CN=$3
TLS_PORT=${TAK_TLS_PORT:-8089}

# ---------------------------------------------------------------------------
# Refuse to run inside a git work tree. This has to run before anything is
# written, and has to work whether or not <out-dir> exists yet.
# ---------------------------------------------------------------------------
check_not_in_git_worktree() {
  local dir="$1"
  local probe="$dir"
  # Walk up to the nearest existing ancestor so `git -C` has somewhere real
  # to run from, even if <out-dir> itself doesn't exist yet.
  while [ ! -d "$probe" ]; do
    probe=$(dirname "$probe")
  done
  probe=$(cd "$probe" && pwd)
  if git -C "$probe" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "REFUSING: '$dir' is inside a git work tree ($(git -C "$probe" rev-parse --show-toplevel))." >&2
    echo "This script writes private key material; it will not write it" >&2
    echo "into anything that could be committed or pushed. Choose an" >&2
    echo "out-dir outside any git work tree (e.g. under your home directory" >&2
    echo "or a scratch/tmp directory) and re-run." >&2
    exit 1
  fi
}
check_not_in_git_worktree "$OUT_DIR"

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

command -v openssl >/dev/null 2>&1 || { echo "openssl not found on PATH" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Password handling: use $TAK_P12_PASSWORD if set, else generate one and
# print it exactly once (it is not written to any file by this script).
# ---------------------------------------------------------------------------
GENERATED_PASSWORD=0
if [ -z "${TAK_P12_PASSWORD:-}" ]; then
  TAK_P12_PASSWORD=$(openssl rand -base64 18 | tr -d '=+/\n')
  GENERATED_PASSWORD=1
fi

gen_uuid() {
  # Not security-sensitive (used only as a MANIFEST cfg uid, per taky's own
  # convention) — RFC4122 version/variant bits are set for well-formedness,
  # nothing more.
  local h
  h=$(openssl rand -hex 16)
  local variant_nibble
  variant_nibble=$(printf '%x' $(( (0x${h:16:1} & 0x3) | 0x8 )))
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "$variant_nibble" "${h:17:3}" "${h:20:12}"
}

# ---------------------------------------------------------------------------
# 1. CA (create, or reuse if already present)
# ---------------------------------------------------------------------------
CA_KEY="$OUT_DIR/ca.key"
CA_CERT="$OUT_DIR/ca.pem"
if [ -f "$CA_KEY" ] && [ -f "$CA_CERT" ]; then
  echo "Reusing existing CA in $OUT_DIR"
else
  echo "Creating CA in $OUT_DIR"
  openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY" || exit 1
  openssl req -x509 -new -key "$CA_KEY" -days 3650 \
    -subj "$(subj_arg 'CN=tak-mtls-ca')" \
    -out "$CA_CERT" || exit 1
fi

# ---------------------------------------------------------------------------
# 2. Server cert, SAN = <server-host-or-ip>
# ---------------------------------------------------------------------------
if printf '%s' "$SERVER_HOST" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  SAN="IP:$SERVER_HOST"
elif printf '%s' "$SERVER_HOST" | grep -q ':'; then
  SAN="IP:$SERVER_HOST"
else
  SAN="DNS:$SERVER_HOST"
fi

SERVER_KEY="$OUT_DIR/server.key"
SERVER_CSR="$OUT_DIR/server.csr"
SERVER_CERT="$OUT_DIR/server.pem"
SERVER_EXT="$OUT_DIR/.server-ext.cnf"
printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$SAN" > "$SERVER_EXT"

openssl ecparam -name prime256v1 -genkey -noout -out "$SERVER_KEY" || exit 1
openssl req -new -key "$SERVER_KEY" -subj "$(subj_arg "CN=$SERVER_HOST")" -out "$SERVER_CSR" || exit 1
openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -days 825 -extfile "$SERVER_EXT" -out "$SERVER_CERT" || exit 1
rm -f "$SERVER_CSR" "$SERVER_EXT" "$OUT_DIR"/ca.srl

# ---------------------------------------------------------------------------
# 3. Client cert, CN = <device-cn>
# ---------------------------------------------------------------------------
CLIENT_KEY="$OUT_DIR/$DEVICE_CN.key"
CLIENT_CSR="$OUT_DIR/$DEVICE_CN.csr"
CLIENT_CERT="$OUT_DIR/$DEVICE_CN.pem"
CLIENT_EXT="$OUT_DIR/.client-ext.cnf"
printf 'extendedKeyUsage=clientAuth\n' > "$CLIENT_EXT"

openssl ecparam -name prime256v1 -genkey -noout -out "$CLIENT_KEY" || exit 1
openssl req -new -key "$CLIENT_KEY" -subj "$(subj_arg "CN=$DEVICE_CN")" -out "$CLIENT_CSR" || exit 1
openssl x509 -req -in "$CLIENT_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -days 825 -extfile "$CLIENT_EXT" -out "$CLIENT_CERT" || exit 1
rm -f "$CLIENT_CSR" "$CLIENT_EXT" "$OUT_DIR"/ca.srl

# ---------------------------------------------------------------------------
# 4. PKCS#12 bundles: <device-cn>.p12 (client cert+key) and truststore.p12
#    (CA cert alone, imported as the trusted root by ATAK/WinTAK).
# ---------------------------------------------------------------------------
CLIENT_P12="$OUT_DIR/$DEVICE_CN.p12"
TRUSTSTORE_P12="$OUT_DIR/truststore.p12"

openssl pkcs12 -export \
  -inkey "$CLIENT_KEY" -in "$CLIENT_CERT" -certfile "$CA_CERT" \
  -name "$DEVICE_CN" \
  -passout "pass:$TAK_P12_PASSWORD" \
  -out "$CLIENT_P12" || exit 1

openssl pkcs12 -export -nokeys \
  -in "$CA_CERT" \
  -name "tak-mtls-ca" \
  -passout "pass:$TAK_P12_PASSWORD" \
  -out "$TRUSTSTORE_P12" || exit 1

if [ "$GENERATED_PASSWORD" -eq 1 ]; then
  echo ""
  echo "Generated PKCS#12 password (shown once, not written to any file):"
  echo "  $TAK_P12_PASSWORD"
  echo ""
fi

# ---------------------------------------------------------------------------
# 5. ATAK/WinTAK data package.
#
# Layout and preference keys below are copied verbatim from taky 0.10's own
# build_client_cmd.py (ATAK branch, lines 99-114 for the preference dict,
# lines 119-136 for the manifest) and datapackage.py (lines 6-47 build_pref,
# lines 50-83 build_manifest) — see header citation. The package root holds
# certs/<...>.p12 x2, a preference file, and MANIFEST/manifest.xml.
# ---------------------------------------------------------------------------
PKG_UID=$(gen_uuid)
PKG_NAME="${DEVICE_CN}-datapackage"
PKG_WORKDIR=$(mktemp -d)
mkdir -p "$PKG_WORKDIR/certs" "$PKG_WORKDIR/MANIFEST"

cp "$TRUSTSTORE_P12" "$PKG_WORKDIR/certs/truststore.p12"
cp "$CLIENT_P12" "$PKG_WORKDIR/certs/$DEVICE_CN.p12"

# datapackage.py build_pref(): one <preference> block per top-level dict key,
# <entry class="class java.lang.{Boolean|Integer|String}"> per field, with
# Boolean values rendered lowercase.
PREF_FILE="$PKG_WORKDIR/$DEVICE_CN.pref"
cat > "$PREF_FILE" <<EOF
<?xml version='1.0' encoding='UTF-8' standalone='yes'?>
<preferences>
  <preference version="1" name="cot_streams">
    <entry key="count" class="class java.lang.Integer">1</entry>
    <entry key="description0" class="class java.lang.String">$SERVER_HOST</entry>
    <entry key="enabled0" class="class java.lang.Boolean">false</entry>
    <entry key="connectString0" class="class java.lang.String">$SERVER_HOST:$TLS_PORT:ssl</entry>
  </preference>
  <preference version="1" name="com.atakmap.app_preferences">
    <entry key="displayServerConnectionWidget" class="class java.lang.Boolean">true</entry>
    <entry key="caLocation" class="class java.lang.String">/storage/emulated/0/atak/cert/truststore.p12</entry>
    <entry key="caPassword" class="class java.lang.String">$TAK_P12_PASSWORD</entry>
    <entry key="clientPassword" class="class java.lang.String">$TAK_P12_PASSWORD</entry>
    <entry key="certificateLocation" class="class java.lang.String">/storage/emulated/0/atak/cert/$DEVICE_CN.p12</entry>
  </preference>
</preferences>
EOF

# datapackage.py build_manifest(): Configuration/Parameter uid+name+
# onReceiveDelete, Contents/Content per zipEntry (certs/truststore.p12,
# certs/<cn>.p12, the preference file).
MANIFEST_FILE="$PKG_WORKDIR/MANIFEST/manifest.xml"
cat > "$MANIFEST_FILE" <<EOF
<?xml version='1.0' encoding='UTF-8' standalone='yes'?>
<MissionPackageManifest version="2">
  <Configuration>
    <Parameter name="uid" value="$PKG_UID"/>
    <Parameter name="name" value="${DEVICE_CN}_DP"/>
    <Parameter name="onReceiveDelete" value="true"/>
  </Configuration>
  <Contents>
    <Content ignore="false" zipEntry="$DEVICE_CN.pref"/>
    <Content ignore="false" zipEntry="certs/truststore.p12"/>
    <Content ignore="false" zipEntry="certs/$DEVICE_CN.p12"/>
  </Contents>
</MissionPackageManifest>
EOF

ZIP_OUT="$OUT_DIR/${PKG_NAME}.zip"
rm -f "$ZIP_OUT"

if command -v zip >/dev/null 2>&1; then
  ( cd "$PKG_WORKDIR" && zip -q -r "$ZIP_OUT" . )
else
  PY_BIN=""
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1; then PY_BIN="$c"; break; fi
  done
  if [ -z "$PY_BIN" ]; then
    echo "Neither 'zip' nor a python interpreter (python3/python/py) is on" >&2
    echo "PATH; cannot build the data package archive. Certs and p12s were" >&2
    echo "still written to $OUT_DIR." >&2
    rm -rf "$PKG_WORKDIR"
    exit 1
  fi
  "$PY_BIN" -c '
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, _dirs, files in os.walk(src):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, src)
            zf.write(full, rel)
' "$PKG_WORKDIR" "$ZIP_OUT" || { rm -rf "$PKG_WORKDIR"; exit 1; }
fi
rm -rf "$PKG_WORKDIR"

echo "Wrote data package: $ZIP_OUT"

# ---------------------------------------------------------------------------
# 6. Print (do not run) the Secret-creation command for the chart side.
# ---------------------------------------------------------------------------
echo ""
echo "Chart-side Secret (keys: server.pem, server.key, ca.pem) — not run, copy/paste:"
echo ""
echo "kubectl create secret generic <egress.tak.tls.secretName> \\"
echo "  --from-file=server.pem=$SERVER_CERT \\"
echo "  --from-file=server.key=$SERVER_KEY \\"
echo "  --from-file=ca.pem=$CA_CERT"
echo ""
echo "Also add \"$DEVICE_CN\" to egress.tak.tls.allowedClientCNs and run helm upgrade."
