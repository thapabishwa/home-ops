# One unit. Run `terragrunt apply` from this directory.
#
# There is no stack split and no dependency wiring, because there is nothing
# left to sequence: the router is already reachable at its final address before
# Terraform runs. See "The bootstrap" in README.md.

locals {
  creds  = read_terragrunt_config("${get_terragrunt_dir()}/credentials.hcl")
  leases = read_terragrunt_config("${get_terragrunt_dir()}/leases.hcl")
}

# Terragrunt 1.0 runs OpenTofu by default, and the two are not interchangeable
# here: .terraform.lock.hcl pins providers from registry.terraform.io, while
# tofu resolves registry.opentofu.org -- a first run is then either a lock
# mismatch or a silent rewrite. It matters offline too. The provider is cached
# under registry.terraform.io, so terraform initialises with no network at all,
# which is the normal state while rebuilding the router that provides the
# network.
terraform_binary = "terraform"

# The RouterOS provider warns about every field it reads but does not model --
# about fifteen on a no-change run, at the same weight as a real problem. Page
# 08 of the docs records what that does: it trains the eye to skip warnings.
# -compact-warnings keeps them, one line each, below the plan summary.
terraform {
  extra_arguments "compact_warnings" {
    commands  = ["plan", "apply"]
    arguments = ["-compact-warnings"]
  }
}

generate "provider" {
  path      = "provider_generated.tf"
  if_exists = "overwrite"
  contents  = <<-EOT
    terraform {
      required_version = ">= 1.5"
      required_providers {
        routeros = {
          source  = "terraform-routeros/routeros"
          version = "~> 1.82"
        }
      }
    }

    variable "router_url" {
      type = string
    }

    variable "router_username" {
      type = string
    }

    variable "router_password" {
      type      = string
      sensitive = true
    }

    provider "routeros" {
      hosturl  = var.router_url
      username = var.router_username
      password = var.router_password

      # Plain HTTP on the LAN. The router presents no trusted certificate, and
      # running a CA for one host on a wire already inside the trust boundary
      # buys nothing.
      insecure = true
    }
  EOT
}

# Without this, state lands inside .terragrunt-cache/ -- a directory Terragrunt
# treats as disposable and rebuilds at will. Losing it means losing the record
# of everything already created, and the next apply tries to build it all a
# second time.
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
  router_url      = local.creds.locals.router_url
  router_username = local.creds.locals.router_username
  router_password = local.creds.locals.router_password
  leases          = local.leases.locals.leases
}
