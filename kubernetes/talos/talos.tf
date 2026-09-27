# From empty VMs to a running cluster.

resource "talos_machine_secrets" "this" {
  talos_version = local.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = local.nodes

  cluster_name     = local.cluster_name
  cluster_endpoint = "https://${local.endpoint}:6443"
  machine_type     = each.value.role
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = local.talos_version

  # Talos 1.14 splits configuration into separate documents, and the generated
  # config already contains them -- so install, kubelet and API server settings
  # are patched as their own kinds. Setting the old `machine.install`,
  # `machine.kubelet` or `cluster.apiServer` fields alongside them is rejected.
  config_patches = concat(
    [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UnattendedInstallConfig"
        installer = {
          # Same schematic as the ISO, or the guest agent extension
          # disappears on the first reboot from disk.
          image = data.talos_image_factory_urls.this.urls.installer
        }
        provisioning = {
          diskSelector = {
            match = "disk.dev_path == \"/dev/sda\""
          }
        }
      }),

      # A pod or service address must never be picked as the node address.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeNodeConfig"
        nodeIP = {
          validSubnets = ["10.0.0.0/24"]
        }
      }),

      # Where local-path-provisioner keeps PersistentVolumes. A `directory`
      # user volume is a plain directory on the EPHEMERAL partition, mounted
      # at /var/mnt/local-path-provisioner -- no extra disk needed.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UserVolumeConfig"
        name       = "local-path-provisioner"
        volumeType = "directory"
      }),

      # Kubelets get serving certificates signed by the cluster CA instead of
      # self-signed ones, so metrics-server can verify them. The requests are
      # approved by kubelet-serving-cert-approver
      # (../infrastructure/controllers/), which must be running first.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeletConfig"
        config = {
          serverTLSBootstrap = true
        }
      }),

      # The Talos API certificate, so talosctl can use the DNS name.
      yamlencode({
        machine = {
          certSANs = ["k8s.internal", local.endpoint]
        }
      }),
    ],
    each.value.role == "controlplane" ? [
      yamlencode({
        apiVersion    = "v1alpha1"
        kind          = "KubeAPIServerConfig"
        certExtraSANs = ["k8s.internal", local.endpoint]
      }),
    ] : [],
  )
}

data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.endpoint]
  nodes                = [for n in local.nodes : n.ip]
}

resource "talos_machine_configuration_apply" "node" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = each.value.ip

  depends_on = [proxmox_virtual_environment_vm.node]
}

# etcd is started exactly once, on the control plane.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.endpoint

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.endpoint

  depends_on = [talos_machine_bootstrap.this]
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}
