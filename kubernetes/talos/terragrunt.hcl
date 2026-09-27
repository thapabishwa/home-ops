# One unit. Run `terragrunt apply` from this directory.
#
# It creates the VMs on pve and turns them into a Talos cluster in the same
# run: the machine config is applied over the Talos API as soon as each VM is
# up in maintenance mode, so there is nothing to sequence by hand.

locals {
  creds = read_terragrunt_config("${get_terragrunt_dir()}/credentials.hcl")
}

# Same reason as ../../home-network/terraform: the lock file pins providers
# from registry.terraform.io, which tofu would either mismatch or rewrite.
terraform_binary = "terraform"

generate "provider" {
  path      = "provider_generated.tf"
  if_exists = "overwrite"
  contents  = <<-EOT
    terraform {
      required_version = ">= 1.5"
      required_providers {
        proxmox = {
          source  = "bpg/proxmox"
          version = "~> 0.116"
        }
        talos = {
          source  = "siderolabs/talos"
          version = "~> 0.12"
        }
      }
    }

    variable "pve_endpoint" {
      type = string
    }

    variable "pve_api_token" {
      type      = string
      sensitive = true
    }

    provider "proxmox" {
      endpoint  = var.pve_endpoint
      api_token = var.pve_api_token

      # pve presents its own self-signed certificate. Same trust argument as
      # the router: the LAN is already inside the boundary.
      insecure = true
    }

    provider "talos" {}
  EOT
}

# State holds the cluster's CA keys and bootstrap tokens, so it stays local
# and gitignored -- and outside .terragrunt-cache/, which Terragrunt treats as
# disposable.
generate "backend" {
  path      = "backend_generated.tf"
  if_exists = "overwrite"
  contents  = <<-EOT
    terraform {
      backend "local" {
        path = "${get_terragrunt_dir()}/terraform.tfstate"
      }
    }
  EOT
}

inputs = {
  pve_endpoint  = local.creds.locals.pve_endpoint
  pve_api_token = local.creds.locals.pve_api_token
}
