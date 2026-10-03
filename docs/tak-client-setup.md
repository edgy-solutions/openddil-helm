# TAK mutual-TLS client setup

This chart can terminate mutual TLS for TAK clients (ATAK-CIV, WinTAK) in
front of the bundled TAK server, admitting devices by certificate CN. The
TAK server itself (`taky`) is unchanged and stays plaintext on its own port;
a `ghostunnel` sidecar does the TLS termination and forwards accepted
connections to it over loopback.

## 1. Values to set

```yaml
egress:
  tak:
    enabled: true
    tls:
      enabled: true
      port: 8089                       # mutual-TLS port, exposed by a Service
      secretName: tak-mtls-certs        # see step 2
      allowedClientCNs:
        - demo-device-01                # one entry per admitted device
      service:
        type: LoadBalancer
```

`helm upgrade` with `egress.tak.tls.enabled=true` and an empty `secretName`
or an empty `allowedClientCNs` list fails the render on purpose — both are
required before the sidecar can do anything.

## 2. Generate certs and create the Secret

```sh
scripts/tak-client-certs.sh <out-dir> <server-host-or-ip> <device-cn>
```

- `<out-dir>` must be outside any git work tree — this writes private key
  material and the script refuses to run otherwise.
- `<server-host-or-ip>` is whatever the device will actually connect to
  (the LoadBalancer's hostname or IP); it becomes the server cert's SAN.
- `<device-cn>` must match an entry you put in `allowedClientCNs` above.

The script prints a `kubectl create secret generic` command using the
generated `server.pem` / `server.key` / `ca.pem` — review it, then run it
yourself against the right namespace:

```sh
kubectl create secret generic tak-mtls-certs \
  --from-file=server.pem=<out-dir>/server.pem \
  --from-file=server.key=<out-dir>/server.key \
  --from-file=ca.pem=<out-dir>/ca.pem
```

Re-run `helm upgrade` after the Secret exists (or after changing
`allowedClientCNs`) — the sidecar's pod picks up a rollout automatically
when either value changes, via a checksum annotation.

The script also writes `<device-cn>-datapackage.zip`: an ATAK/WinTAK data
package carrying the device's client certificate, the CA truststore, and a
stream preference already pointed at your server and port.

## 3. ATAK-CIV setup

Menu names below are the usual ones and vary between ATAK and WinTAK
releases; the settings themselves (SSL, host, port, the two p12 files and
their password) do not.

Easiest path — import the data package:

1. Copy `<device-cn>-datapackage.zip` onto the device (file share, USB,
   mission package import over an existing connection, etc).
2. In ATAK: **Settings → Import → Import Data Package**, select the zip.
3. The stream appears under **Settings → Network Preferences → TAK
   Servers**; enable it if it is not already connecting.

Manual path, if you'd rather not use the package:

1. Import `<device-cn>.p12` as a client certificate and `truststore.p12` as
   the CA truststore (**Settings → Network Preferences → SSL/TLS**).
2. Add a TAK server with protocol `ssl`, host = your server host/IP, port =
   `egress.tak.tls.port`.

## 4. WinTAK setup

Same two artifacts, different menu: **Settings → TAK Server Configuration →
Add → Import from Data Package**, or manually add a server with Transport =
`SSL`, the two p12 files, and the same host/port.

## 5. Verifying it worked

- The server entry on the device shows connected/green, not red or
  grey.
- Tracks from the demo scenario start showing up on the device within the
  sim's normal publish interval.
- On the cluster side, the sidecar's pod logs (container `tls-proxy`) show
  an accepted connection with the device's CN; a rejected device (wrong CN,
  wrong CA, or no cert) shows there instead, not in `taky`'s own logs —
  `taky` never sees rejected connections.

## 6. Revoking a device

1. Remove the device's CN from `egress.tak.tls.allowedClientCNs`.
2. `helm upgrade` — the sidecar restarts with the shorter `--allow-cn` list
   and starts rejecting that CN immediately, even though its certificate is
   still otherwise valid (same CA, not expired).

Deleting the device's key material is good hygiene but not what actually
revokes access — the `allowedClientCNs` list is what the sidecar enforces.

## 7. The audience warning

Admitting a CN does not scope that device to anything narrower than the
whole audience of the one destination this TAK server serves
(`egress.destination`): admitting a device admits it to that audience. There is no per-track,
per-unit, or per-message filtering at the TLS layer — `--allow-cn` is an
admission decision, not a releasability decision. Treat every CN you add to
`allowedClientCNs` as fully trusted with everything this TAK server emits.
