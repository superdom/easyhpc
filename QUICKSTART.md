# EasyHPC Quick Start

Deploy a SLURM cluster with GPU/container support and monitoring via Ansible.

## Read this first
- `docs/01-installation.md`: phase order, optional components, and rationale
- `docs/02-slurm-controller-ha.md`: HA rollout and validation
- `docs/03-slurm-build-environment.md`: hwloc/PMIx/Slurm build chain
- `docs/04-modules-and-build-workflows.md`: Lmod + EasyBuild workflow
- `docs/05-ldap.md`: LDAP integration (optional)
- `docs/06-firewall-setup.md`: required ports and firewall guidance

## Defaults and required inventory groups
| Feature | Default | Inventory group(s) |
| --- | --- | --- |
| HA (slurmctld) | enabled (`ha_enabled: true`) | `slurm-controller` (>= 2 hosts) |
| Accounting (slurmdbd + DB) | enabled (`slurm_accounting_enabled: true`) | `slurm-controller` (DB on the first host) |
| Monitoring | enabled (`monitoring_enabled: true`) | `monitoring` |
| Logging (Loki/Alloy) | enabled (`loki_enabled: true`, `alloy_enabled: true`) | `logging` |
| Shared storage (NFS) | enabled (`shared_storage_mount: /data`) | `nfs-server` (server) + `nfs-client` |
| EasyBuild | disabled (`easybuild_enabled: false`) | `easybuild` |

## Prerequisites
- Control node: Ansible 2.20+, Python 3.12+
- Targets: RHEL/Rocky 9 or Ubuntu 22.04/24.04 (x86_64), SSH + sudo
- Keys: passwordless SSH to all hosts
- Firewall: follow `docs/06-firewall-setup.md` to open required ports

## 1) Inventory
Edit `config/inventory`:
```ini
[slurm-controller]
easyhpc-mgmt01 ansible_host=10.0.0.11
easyhpc-mgmt02 ansible_host=10.0.0.12

[slurm-node]
easyhpc-cpu01 ansible_host=10.0.0.21
easyhpc-cpu02 ansible_host=10.0.0.22

[slurm-login]
easyhpc-login ansible_host=10.0.0.31

[nfs-server]
easyhpc-mgmt04 ansible_host=10.0.0.14

[nfs-client:children]
slurm-controller
slurm-node
slurm-login

[monitoring]
easyhpc-mgmt03 ansible_host=10.0.0.13

[logging]
easyhpc-mgmt03 ansible_host=10.0.0.13

[ldap]
easyhpc-mgmt03 ansible_host=10.0.0.13

[easybuild]
easyhpc-mgmt01 ansible_host=10.0.0.11
```

## 2) Variables
Tune `config/group_vars/`:
- `all.yml`: cluster identity, DNS, service users, shared storage base path, NFS settings, module tree defaults, node group helpers.
- `services.yml`: runtime (Docker/Enroot/Pyxis/GPU) + monitoring/logging toggles (defaults: enabled).
- `slurm.yml`: Slurm build/install, directory paths, ports, partitions (default `compute`), Generic Resource (GRES, e.g., GPU),
  slurm.conf, accounting/DB, HA, EasyBuild settings.
OS-specific package/repo defaults now live in role defaults; override in group_vars if needed.

## 3) Ansible venv
```bash
./scripts/setup-ansible-env.sh
source venv/bin/activate
```

## 4) Connectivity
```bash
ansible all -i config/inventory -m ping
```

## Preconditions (before deploy)
- HA (default enabled): requires >= 2 controllers and shared storage mounted at the configured state path.
- Accounting (default enabled): requires MariaDB/MySQL on the primary controller (or a dedicated DB host).
- Monitoring/Logging (default enabled): requires Docker on the monitoring/logging nodes.
- Logging (default enabled): requires the `[logging]` inventory group (used to build Loki URLs).
- Single controller: set `ha_enabled: false` in `config/group_vars/slurm.yml`.
Note: If `[nfs-server]` exists and `nfs_enable_server: true`, EasyHPC configures `nfs_exports` on the server and mounts
`nfs_mounts` on hosts in `[nfs-client]` (keep the server out of `[nfs-client]`).

## 5) Deploy
- Full:  
  `ansible-playbook -i config/inventory playbooks/slurm-cluster.yml`
- Phased examples (runnable tag bundles):  
  `--tags common` (common baseline)  
  `--tags ha-slurm,slurm-mysql,hwloc,pmix,slurm` (Slurm core stack)
  `--tags lmod,nhc,pyxis` (Slurm add-ons)
  `--tags nvidia-driver,docker,nvidia-container-toolkit,enroot,pyxis` (GPU + containers)  
  `--tags monitoring,alertmanager,prometheus-node-exporter,prometheus-slurm-exporter,nvidia-dcgm-exporter,loki,alloy` (observability)  
  `--tags lmod,easybuild` (EasyBuild)

**Note**: Some components are intentionally gated in this repo:
- GPU stack installs only on nodes where GPUs are detected (no `gpu_enabled` toggle).
- Monitoring/logging are enabled by default. Toggle in `config/group_vars/services.yml`.
- EasyBuild is disabled by default (`easybuild_enabled: false`) to avoid long initial build times. Enable in `config/group_vars/slurm.yml`, ensure build hosts are in the `[easybuild]` inventory group, then run with `--tags easybuild`.
- LDAP roles are commented out in `playbooks/slurm-cluster.yml` until you complete the prerequisites in `docs/05-ldap.md` (then uncomment them, and run with `--tags ldap-server,ldap-client`).

## 6) Validate
```bash
ansible-playbook -i config/inventory playbooks/slurm-validation.yml
```

## 7) Use SLURM
```bash
srun hostname
srun --gres=gpu:1 nvidia-smi
squeue
sinfo -Nel
```

## More documentation
- `README.md`
- `docs/01-installation.md`
