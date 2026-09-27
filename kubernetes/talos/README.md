# Talos on Proxmox

Implementation notes for the cluster's one Terragrunt unit: the two VMs, their Talos configuration, the cluster bootstrap and the kubeconfig. Why the cluster exists is in the [Overview](../README.md).

```sh
terragrunt plan
terragrunt apply
```

## What it builds

| Node | VM | Address | vCPU | RAM | Disk |
|---|---|---|---|---|---|
| `talos-cp-1` (control plane) | 110 | 10.0.0.20 | 2 | 8 GiB | 20 GiB |
| `talos-w-1` (worker) | 111 | 10.0.0.21 | 4 | 16 GiB | 40 GiB |

Talos v1.14.2, Kubernetes 1.37. Providers `bpg/proxmox` and `siderolabs/talos`, pinned in `.terraform.lock.hcl`.

## How it builds without manual steps

1. pve downloads a Talos ISO from the image factory, built from a schematic that adds the QEMU guest agent. Nothing passes through the machine running Terraform.
2. The VMs boot it in maintenance mode. A cloud-init drive, read by the `nocloud` image, gives each node its final address, so Terraform knows where to send config.
3. Talos installs to disk with the installer from the same schematic (otherwise the guest agent disappears on first reboot) and reboots. The disk is first in boot order, so the ISO is used once.
4. etcd is bootstrapped on the control plane and a kubeconfig is issued.

Terraform doesn't wait for the guest agent to report an address: in maintenance mode it may not, and the provider would sit out a 15-minute timeout for an address that is static anyway.

## The config patches

Talos 1.14 config is multi-document, and the generated config already contains the install, kubelet and API server documents. A patch to the old `machine.install`, `machine.kubelet` or `cluster.apiServer` fields is rejected by the node with `... is already set in v1alpha1 config`; Terraform validation doesn't catch it ([Incidents](../docs/07-incidents.md)). The patches in [`talos.tf`](talos.tf):

| Document | Sets | Why |
|---|---|---|
| `UnattendedInstallConfig` | install disk, installer image | same schematic as the ISO |
| `KubeNodeConfig` | `nodeIP.validSubnets: 10.0.0.0/24` | a pod or service address must never be picked as the node's |
| `KubeletConfig` | `serverTLSBootstrap: true` | kubelets get CA-signed serving certificates, so metrics-server can verify them |
| `UserVolumeConfig` | `local-path-provisioner`, `volumeType: directory` | where PersistentVolumes live; a directory on the system partition, no extra disk |
| `machine.certSANs` | `k8s.internal`, `10.0.0.20` | the Talos API answers to its DNS name |
| `KubeAPIServerConfig` (control plane) | `certExtraSANs` | the Kubernetes API answers to `k8s.internal` |

Render them locally before applying: a scratch Terraform config with only `talos_machine_secrets` and `talos_machine_configuration` shows the merged documents in seconds, with no VMs.

Apply the `KubeletConfig` patch before Flux installs metrics-server, which can't become healthy until kubelets have the new certificates.

## Prerequisites

Done by hand once; Terraform never creates the account it authenticates as:

```sh
# on pve
pveum role add TerraformProv -privs 'Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Pool.Audit Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.PowerMgmt VM.GuestAgent.Audit SDN.Use'
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role TerraformProv
pveum user token add terraform@pve talos --privsep 0
```

The token goes into `credentials.hcl` (gitignored):

```hcl
locals {
  pve_endpoint  = "https://10.0.0.3:8006/"
  pve_api_token = "terraform@pve!talos=<secret>"
}
```

## After apply

```sh
terragrunt output -raw talosconfig > talosconfig
terragrunt output -raw kubeconfig  > kubeconfig
export TALOSCONFIG=$PWD/talosconfig KUBECONFIG=$PWD/kubeconfig

talosctl health --nodes 10.0.0.20
kubectl get nodes -o wide
```

Both files are admin credentials and gitignored. For a desktop client such as Lens, merge into `~/.kube/config` (context `admin@home`).

Then Flux, through the Flux Operator, once:

```sh
# 1. the operator
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system --create-namespace

# 2. a read-only deploy key: generate it, add the .pub to the GitHub repo as a
#    deploy key (no write access), and give the private half to the cluster
ssh-keygen -t ed25519 -N '' -C flux-home -f flux-deploy-key
flux-operator create secret ssh flux-system --namespace=flux-system \
  --private-key-file=flux-deploy-key --knownhosts-file=<(ssh-keyscan github.com)

# 3. Flux itself, from the repo
kubectl apply -f ../clusters/home/flux-instance.yaml
```

The operator installs the controllers and syncs `kubernetes/clusters/home`, which brings up everything else, including the operator's own HelmRelease, which takes over from the `helm install`.

## State

`terraform.tfstate` is local and gitignored. It holds the cluster's CA keys, etcd secrets and bootstrap tokens; losing it doesn't stop the cluster, but Terraform can no longer manage it.
