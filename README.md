# EasyHPC

Ansible playbooks to deploy a SLURM cluster (controller, compute, optional login), with GPU/container support and monitoring.

## What's Included
- SLURM controller/compute provisioning (Slurm configless mode: controller distributes `slurm.conf`)
- GPU & containers: NVIDIA driver, Docker, NHC (Node Health Check), Enroot, Pyxis
- Shared storage: NFS client/server
- Software stack: Lmod, EasyBuild
- Logging: Loki (log aggregation), Alloy (log agent)
- Monitoring: Prometheus + exporters (node, SLURM, DCGM), Grafana, Alertmanager

## Documentation
- `QUICKSTART.md`: fast path for first deployment
- `docs/01-installation.md`: phase order and rationale (optional phases included)
- `docs/02-slurm-controller-ha.md`: controller HA design and rollout
- `docs/03-slurm-build-environment.md`: hwloc/PMIx/Slurm build chain
- `docs/04-modules-and-build-workflows.md`: Lmod + EasyBuild workflows
- `docs/05-ldap.md`: LDAP integration (OpenLDAP + SSSD)
- `docs/06-firewall-setup.md`: required ports and firewall patterns

## Requirements
- OS: RHEL 9, Rocky 9, Ubuntu 22.04/24.04 (x86_64)
- Ansible 2.20+, Python 3.12+ on the control host
- SSH with sudo access to all targets
- ~10GB free space on each node

## Configure
1) Inventory: edit `config/inventory` (controller, nodes, login, NFS/monitoring as needed).  
2) Vars: adjust `config/group_vars/all.yml`, `services.yml`, `slurm.yml` (storage, GPUs, EasyBuild settings, partition names, versions, etc.).  
   - OS-specific package/repo defaults live in role defaults; override in group_vars if needed.
   - See `docs/01-installation.md` for phase order and optional components.
3) Optional venv: `./scripts/setup-ansible-env.sh && source venv/bin/activate` (auto-activated in new shells).  
4) Connectivity check: `ansible all -i config/inventory -m ping`.

## Deploy
- Full: `ansible-playbook -i config/inventory playbooks/slurm-cluster.yml`
- Phased examples (runnable tag bundles):
  - Common baseline: `--tags common`
  - Slurm core stack: `--tags ha-slurm,slurm-mysql,hwloc,pmix,slurm`
  - GPU + containers: `--tags nvidia-driver,docker,nvidia-container-toolkit,enroot,pyxis`
  - Observability (monitoring + exporters + logging): `--tags monitoring,alertmanager,prometheus-node-exporter,slurm-exporter,nvidia-dcgm-exporter,loki,alloy`
  - EasyBuild: `--tags lmod,easybuild`

## Validate
```bash
ansible-playbook -i config/inventory playbooks/slurm-validation.yml
```
## Monitoring
- Grafana: http://<monitoring-host>:3000
- Logs: slurmctld `/var/log/slurm/slurmctld.log`, slurmd `/var/log/slurm/slurmd.log`

## Useful Notes
- Firewall policy and ports: see `docs/06-firewall-setup.md`.

## Layout
```
playbooks/                 # slurm-cluster.yml, slurm-validation.yml
config/                    # inventory + group vars
roles/                     # common, slurm, gpu/container, storage, monitoring, etc.
scripts/                   # setup-ansible-env.sh, cpu-binding-test.sbatch, mpi-test.sbatch
docs/                      # additional guides
```

## Support
Issues and PRs are welcome. See `docs/` and `QUICKSTART.md` for detail.

## Contributing
1. Fork this repository
2. Create a feature branch (`git checkout -b feature/xxx`)
3. Commit your changes
4. Push to your fork and open a Pull Request

## License
- This project is licensed under the MIT License.
