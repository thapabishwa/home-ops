# Incidents

Nine problems during the build, all on one day. None reached the household.

## A false "all WANs down"

**What happened:** the ISP watcher wrote `CRIT ALL WANS DOWN` to a scratch log while all three lines were up.
**Cause:** the router's REST account rejected the worker's address, where pod traffic comes from. Every call returned 401, which the watcher read as down.
**Fix:** the account accepts the worker's address ([State and secrets](06-state-and-secrets.md)).
**Lesson:** test a monitor against the real thing, writing somewhere disposable first; the outage record is evidence.

## Talos rejected its own patches

**What happened:** the first `terragrunt apply` created both VMs, then failed applying their config:

```
UnattendedInstallConfig config is incompatible with v1alpha1 config (.machine.install)
.machine.kubelet.nodeIP is already set in v1alpha1 config
kube-apiserver config is already set in v1alpha1 config (.cluster.apiServer)
```

**Cause:** Talos 1.14 moved these settings into separate documents (`UnattendedInstallConfig`, `KubeNodeConfig`, `KubeletConfig`, `KubeAPIServerConfig`); patching the old fields collides. Terraform validation passed.
**Fix:** I rewrote the patches, checked by rendering locally, while the VMs waited in maintenance mode ([Talos](../talos/README.md)).

## A template engine inside the values

**What happened:** the Homepage release failed to render:

```
template: gotpl:31: function "HOMEPAGE_VAR_PROXMOX_TOKEN" not defined
```

**Cause:** the bjw-s `app-template` chart runs values through Helm's `tpl`, so Homepage's `{{HOMEPAGE_VAR_...}}` placeholder looked like a function call. Then a comment explaining the escape broke it again: comments are templated too.
**Fix:** escaped both; local rendering caught each before Flux saw it.

## "Routing is broken" that was not

**What happened:** right after a deploy, five names served the catch-all redirect. Traefik logged, once per name:

```
ERR Error configuring TLS error="secret lan-proxy/<name>-internal-tls does not exist"
```

**Cause:** Traefik drops an Ingress until its TLS Secret exists. The resources were 51 seconds old.
**Fix:** none; cert-manager issued within seconds.
**Lesson:** on a first deploy, wait for `kubectl get certificate` to show `READY True`.

## A health check that tested the wrong thing

**What happened:** "Router DNS" went red when `home.internal`'s record moved to Traefik.
**Cause:** it expected `home.internal`'s old address; the new answer, `10.0.0.30`, was correct. It tested where a service lived.
**Fix:** it queries `pve.internal`, which proxies don't move ([Monitoring](05-monitoring.md)).

## An ordering trap in Flux

**What happened:** `infra-controllers` sat out its five-minute timeout on metrics-server, every app waiting behind it.
**Cause:** metrics-server needs CA-signed kubelet certificates from a Talos change applied outside Flux. I pushed first.
**Fix:** apply the Talos change before the push.

## Debugging a cluster before it existed

**What happened:** three "failures" were checks run before their subject existed: `kubectl get certificate` before cert-manager, a feed while its pod pulled its image, routes before certificates.
**Cause:** Flux showed `Reconciliation in progress` each time.
**Fix:** run `flux get kustomizations` first; while in progress, nothing else is evidence.

## A token that should not have been copied

**What happened:** Homepage's Proxmox API token sat in plain text in a config file that had been copied around.
**Fix:** I rotated it; the new one lives only in a Secret.

## A routing fix the cluster would not run

**What happened:** qBittorrent's second interface needs source routing (10.0.0.11 out via the router, the rest on the cluster network). My init container with `NET_ADMIN` was refused at admission.
**Cause:** `baseline` Pod Security forbids that capability; relaxing the namespace would let any pod in it reconfigure its network.
**Fix:** the `sbr` CNI plugin, chained after macvlan, builds the table at interface creation, with no pod privileges. A throwaway pod on a spare address proved it (LAN reachable, cluster routes untouched) before I stopped qBittorrent ([Networking](02-networking.md)).
**Lesson:** when a pod needs a capability to fix its own plumbing, have the plumbing do it.
