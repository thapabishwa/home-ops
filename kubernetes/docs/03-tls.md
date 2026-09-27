# TLS

No public CA issues certificates for `.internal`, so the cluster runs a household CA with cert-manager.

## The household CA

Three objects in [`infrastructure/configs/internal-ca.yaml`](../infrastructure/configs/internal-ca.yaml):

| | |
|---|---|
| `selfsigned` | a ClusterIssuer that bootstraps exactly one thing, the root |
| `internal-root-ca` | 10-year ECDSA P-256 root, key never rotated |
| `internal-ca` | the ClusterIssuer every Ingress names |

An Ingress annotated `cert-manager.io/cluster-issuer: internal-ca` gets a 90-day certificate, renewed automatically.

The root has `rotationPolicy: Never`: a new key on renewal would break every device that trusts it.

## Name constraint

The root carries a critical X.509 name constraint permitting only `.internal`:

```yaml
nameConstraints:
  critical: true
  permitted:
    dnsDomains: [internal]
```

A device that trusts it rejects anything it signs outside `.internal`, so a leaked key cannot be used against a bank or mail provider.

## HTTP to HTTPS

Each browser-facing Ingress references a `redirect-https` middleware, set per Ingress so three names can opt out:

- **`jellyfin.internal`**: the TV app uses plain HTTP, and Android TV apps ignore user-installed CAs. HTTPS still works for browsers.
- **`dash.internal`**: pve PUTs the battery reading with `curl` every minute.
- **`ca.internal`**: serves the CA to devices that don't trust it yet.

HTTPS on the TV needs a real domain with Let's Encrypt via DNS-01 (see [What's next](../README.md)).

## Proxmox, verified TLS

Proxmox cannot be proxied over HTTP: its login sets a `Secure` cookie in JavaScript, which browsers drop on HTTP pages. Over HTTPS the Traefik-to-pve hop is verified:

- pve's certificate comes from pve's cluster CA, for `pve`, `pve.homelab` and `localhost`.
- A Traefik `ServersTransport` checks it against pve's root and the name `pve`. The root is public (`/etc/pve/pve-root-ca.pem`), committed in [`apps/lan-proxy/pve-tls.yaml`](../apps/lan-proxy/pve-tls.yaml).
- pve renews its node certificate under the same root, valid until **September 2036**.

The browser sees the household CA's certificate for `proxmox.internal`, never pve's.

## How the health checks trust the CA

cert-manager writes the issuing CA into every certificate Secret as `ca.crt`. Blackbox mounts that key from `prometheus.internal`'s certificate Secret in the same namespace, and its `http_2xx_household` module names it as `ca_file`. No committed copy needed.

## Trusting it on a device

Download from **http://ca.internal**, plain HTTP on purpose (only the certificate is mounted, not the key). Or, with cluster access:

```sh
kubectl -n cert-manager get secret internal-root-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > home-internal-ca.crt

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain home-internal-ca.crt
# iPhone/iPad: AirDrop the file, install the profile, then
#   Settings > General > About > Certificate Trust Settings > enable it
```

## Kubelet serving certificates

Unrelated to the household CA. Talos sets `serverTLSBootstrap`, so kubelets request certificates from the cluster CA and kubelet-serving-cert-approver approves them after checking the node; metrics-server then verifies kubelets without `--kubelet-insecure-tls`.
