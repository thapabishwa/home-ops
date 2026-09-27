# home-ops

Notes and configuration for what I run at home: reference docs, runbooks and
postmortems. Published at
[thapabishwa.gitbook.io/home-ops](https://thapabishwa.gitbook.io/home-ops);
this repository is the source.

| | |
|---|---|
| [`design.md`](design.md) | The whole system on one page: objective, constraints, decisions, what would change it |
| [`home-network/`](home-network/README.md) | Three ISPs behind one MikroTik hEX: tiers, failover, monitoring |
| [`home-network/terraform/`](home-network/terraform/README.md) | The router's configuration, one Terragrunt unit |
| [`home-network/tools/`](home-network/tools/) | Failover drill harness, controller replay and tests |
| [`kubernetes/`](kubernetes/README.md) | Two-node Talos cluster, deployed by Flux from this repo |
| [`proxmox/`](proxmox/README.md) | The host underneath, applied by Ansible |

## Conventions

- Anything managed as code converges: a run with nothing to do reports no
  changes.
- Secrets are SOPS-encrypted, or live in gitignored files beside the config
  that reads them.
- Numbers are measured or sourced; estimates say so.
