# The cluster: one control plane, one worker, both VMs on pve.
#
# Two nodes on one physical machine. That is enough to practise scheduling,
# draining and upgrades; it is not high availability, and it does not pretend
# to be -- the laptop is the failure domain for both.

locals {
  talos_version = "v1.14.2"
  cluster_name  = "home"
  gateway       = "10.0.0.1"

  # The API endpoint is the control plane's own address. With one control
  # plane there is nothing for a VIP to float between.
  endpoint = "10.0.0.20"

  # Addresses are static, set through the cloud-init drive that the nocloud
  # image reads -- so each node is reachable at its final address while still
  # in maintenance mode, and Terraform knows where to send the config.
  # DNS names for these are in ../../home-network/terraform/addressing.tf.
  nodes = {
    "talos-cp-1" = { vmid = 110, ip = "10.0.0.20", role = "controlplane", cores = 2, memory = 8192, disk = 20 }
    "talos-w-1"  = { vmid = 111, ip = "10.0.0.21", role = "worker", cores = 4, memory = 16384, disk = 40 }
  }
}

# The image is built by the Talos image factory from this schematic. The guest
# agent extension lets Proxmox shut the VMs down cleanly and see their
# addresses.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = local.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
}

# pve downloads the ISO itself; nothing passes through this machine.
resource "proxmox_download_file" "talos_iso" {
  node_name    = "pve"
  datastore_id = "local"
  content_type = "iso"
  url          = data.talos_image_factory_urls.this.urls.iso
  file_name    = "talos-${local.talos_version}-${substr(talos_image_factory_schematic.this.id, 0, 8)}-nocloud-amd64.iso"
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.nodes

  node_name = "pve"
  vm_id     = each.value.vmid
  name      = each.key
  tags      = ["talos", "kubernetes", each.value.role]
  on_boot   = true

  # q35 for PCIe passthrough later (the iGPU, for Jellyfin). It only exposes
  # ide0 and ide2, so the ISO takes ide0 and cloud-init keeps its default ide2.
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  operating_system {
    type = "l26"
  }

  # Talos needs x86-64-v2; `host` passes the i7-8850H through as-is.
  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  agent {
    enabled = true

    # In maintenance mode the agent may not report an address yet, and the
    # provider would otherwise sit out its 15-minute timeout. The address is
    # static and known anyway.
    wait_for_ip {
      disabled = true
    }
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk
    file_format  = "raw"
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  cdrom {
    interface = "ide0"
    file_id   = proxmox_download_file.talos_iso.id
  }

  # Disk first. On the first boot it is empty and SeaBIOS falls through to the
  # ISO; after Talos installs itself, the disk wins and the ISO is never used
  # again.
  boot_order = ["scsi0", "ide0"]

  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = local.gateway
      }
    }

    dns {
      servers = [local.gateway]
      domain  = "internal"
    }
  }
}
