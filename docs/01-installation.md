# EasyHPC Installation Order and Rationale

## Overview
This document explains the *sequence* of the EasyHPC deployment and why each
step must occur when it does. The playbook is intentionally ordered to satisfy
authentication, build-time, and runtime dependencies across controller, compute,
and login nodes.

Shared storage is optional by design, but this repo enables NFS-backed shared
storage by default (`shared_storage_mount: /data` in `config/group_vars/all.yml`,
`nfs_enable_server: true` and `nfs_enable_client: true` in
`config/group_vars/all.yml`). Within Phase 4 (Slurm stack), HA and
accounting are optional, but defaults enable them
(`ha_enabled: true` and `slurm_accounting_enabled: true` in
`config/group_vars/slurm.yml`). GPU and container support is still conditional
because many environments do not have GPUs or restrict kernel features and
container runtimes. Monitoring/logging is optional but enabled by default
(`monitoring_enabled`, `loki_enabled`, and `alloy_enabled` in
`config/group_vars/services.yml`). Disable any of these in group vars
if you want a minimal deployment.


**Phase 4 is the Slurm stack**
- Optional control-plane prerequisites (HA)
- Optional accounting DB (`slurmdbd`)
- Build prerequisites (hwloc/PMIx)
- Slurm core install and configuration

## Order at a glance
```
Phase 1: Common baseline (identity, time, auth prerequisites)
Phase 2: GPU and container runtime prerequisites
Phase 3: Setup shared storage (optional)
Phase 4: Slurm stack (optional components controlled by ha_enabled/slurm_accounting_enabled)
  4.1: HA prerequisites for Slurm control plane (optional; controlled by ha_enabled)
  4.2: Accounting database for slurmdbd (optional; controlled by slurm_accounting_enabled)
  4.3: Build prerequisites (hwloc, pmix)
  4.4: Slurm core install and configuration
Phase 5: Slurm add-ons (Pyxis, Lmod, NHC) (optional; controlled by pyxis_enabled/lmod_enabled/nhc_enabled)
Phase 6: Software build tooling (EasyBuild) (optional; controlled by easybuild_enabled)
Phase 7: Monitoring and logging (optional; controlled by monitoring_enabled/loki_enabled/alloy_enabled)
Phase 8: LDAP server/client (optional; controlled by ldap_enabled)
Post-install validation and service checks
```

---

## Phase 1: Common Baseline Configuration

### Purpose
Establish a consistent operating system baseline and identity configuration required by Slurm and its authentication mechanisms.

### Scope
- All nodes (controller, compute, login)

### Why this order
- Slurm services rely on Munge for authentication.
- A shared Munge key and consistent UID/GID mapping must exist before any Slurm component is started.
- Time synchronization and system limits must be stable to prevent:
  - Scheduling inconsistencies  
  - Resource accounting inaccuracies  

### Notes
- This phase is mandatory and must complete successfully before any subsequent phase.

---

## Phase 2: GPU and Container Runtime Prerequisites

### Purpose
Prepare nodes for GPU-enabled workloads and container-based job execution.

### Scope
- GPU nodes and/or container-enabled nodes

### Why this order
- Slurm configuration (for example, GRES and container integration) assumes GPU drivers and container runtimes are already present.
- Installing these components later would require Slurm reconfiguration and service restarts across nodes.

### Notes
This phase runs automatically on GPU nodes. Container runtimes are still controlled by:
- `docker_enabled`
- `enroot_enabled`

### Skip Conditions
- No GPUs are present  
- Container runtimes are restricted by kernel or security policy  

---

## Phase 3: Shared Storage Setup (Optional)

### Purpose
Provide shared filesystem paths for:
- Slurm configuration and state
- Module trees and software stacks

### Scope
- Storage server nodes
- All nodes mounting shared paths

### Why this order
- Shared paths must exist before Slurm configuration files, HA state directories, or module trees are created.
- Early availability prevents inconsistent or unintended local directory creation.

### Notes
- NFS is suitable for small or low-concurrency clusters.
- For heavy I/O or large-scale environments, a parallel filesystem (for example, Lustre) is recommended.

### Skip scenarios
- External shared storage is already mounted at a consistent path on all nodes.
- You want to manage storage outside EasyHPC. In that case, set
  `nfs_enable_server: false` and `nfs_enable_client: false` (or set
  `nfs_mounts: []`) in `config/group_vars/all.yml`.

### NFS behavior (default)
- If the `[nfs-server]` group exists and `nfs_enable_server: true`, EasyHPC
  exports `nfs_exports` from the server.
- If `nfs_enable_client: true`, EasyHPC mounts `nfs_mounts` on hosts in
  `[nfs-client]` (keep the server out of `[nfs-client]`).
- The NFS fstab entry uses `_netdev,nofail,x-systemd.automount` so nodes can
  boot even if NFS is temporarily unavailable.

### Required Configuration Adjustments (External Shared Storage)
```yaml
# config/group_vars/all.yml
shared_storage_mount: "/data"
modules_manage_shared_paths: true
modules_base_path: "{{ shared_storage_mount }}/apps"
modules_storage_path: "{{ modules_base_path }}"
modules_storage_host: "<node-with-external-mount>"
```

```yaml
# config/group_vars/all.yml
nfs_enable_server: false
nfs_enable_client: false
# or: nfs_mounts: []
```

```yaml
# config/group_vars/slurm.yml
ha_enabled: true
# HA only
# slurm_state_save_location_ha: "{{ shared_storage_mount }}/.slurm_state"
```

```yaml
# config/group_vars/ldap.yml (optional)
ldap_home_prefix: "{{ shared_storage_mount }}/users"
```

**Path rule**
- Shared service paths should live on a mounted filesystem (not `/`).
  The playbook validates that shared paths resolve to a mounted target.

**Mixed storage cautions (internal NFS + external storage)**
- Ensure each mountpoint exists on all relevant nodes before running the playbook.
- Point each service to the intended mount path (for example, `/data/.slurm_state` or `/data/apps`).
- If you do not want EasyHPC to create directories on shared storage, set
  `modules_manage_shared_paths: false` and create the structure manually.

### NFS export security
- Wildcard `*` is removed from `/etc/exports`; exports are rendered from
  inventory hosts only.
- `[slurm-controller]` and `[easybuild]` are exported with `no_root_squash`;
  every other host in `[nfs-client]` is exported with `root_squash`.
- Login nodes are intentionally not trusted; do not run root tasks against
  shared paths from a login shell.
- `root_squash` blocks `chown`/`chmod` only — it does not block read of
  world-readable files. Pair with `umask 027`, home `0700`, and group ACLs
  for project directories.
- Pre-create LDAP user home directories on the NFS server; `pam_mkhomedir`
  fails on `root_squash` clients (see `docs/05-ldap.md`).

`nfs_exports` accepts a structured form (default) or a raw `options` string
that renders verbatim — use the latter for CIDR or path-level splits:
```yaml
# raw override
nfs_exports:
  - path: /data
    options: "10.0.0.0/24(rw,sync,no_root_squash,no_subtree_check)"
```

Verify before deploy:
```bash
ansible -i config/inventory nfs-server -m debug -a "var=nfs_exports"
ansible-playbook -i config/inventory playbooks/slurm-cluster.yml \
  --tags nfs-server --check --diff
```

---
## Phase 4: Slurm Stack

This phase groups the components required to stand up Slurm. Subtasks 4.1-4.4
cover optional HA and accounting, required build dependencies, and the core
Slurm install/configuration.

### Configless Slurm (Compute Nodes)

Use Slurm configless mode so compute nodes fetch their runtime configuration
from the controller and cache it under `SlurmdSpoolDir/conf-cache`.

**Requirements**
- Controller(s) reachable on `SlurmctldPort` (default 6817).
- `SlurmdParameters=enable_configless` and `SlurmctldParameters=enable_configless`.

**Controller settings**
- `SlurmctldParameters=enable_configless` in `slurm.conf`, then restart `slurmctld`.
- Optional but recommended for minimal local config: `DebugFlags=NO_CONF_HASH`
  to suppress config hash mismatch warnings.

**Compute node settings**
- Minimal local `/etc/slurm/slurm.conf` with:
  - `ClusterName`, `SlurmctldHost` (HA uses multiple lines), `SlurmctldPort`
  - `AuthType`, `SlurmdSpoolDir`
  - `SlurmdParameters=enable_configless`
  - `NodeName=<this-node>` (required unless `slurmd -N` is used)

**Start `slurmd`**
- Use `--conf-server` pointing to controllers, for example:
  `slurmd --conf-server=easyhpc-mgmt01:6817,easyhpc-mgmt02:6817`

**Validation**
- `ls -l /var/spool/slurm/slurmd/conf-cache` should show fetched config files.
- `scontrol show node <node>` should be `IDLE` (if DRAINed, `scontrol update
  NodeName=<node> State=RESUME` after fixing the reason).

**Common issues**
- `Address already in use`: stale `slurmd` process still bound to 6818.
- `Unable to determine this slurmd's NodeName`: missing `NodeName` in the
  local stub.

### Phase 4.1: High-Availability Prerequisites (Optional)

### Purpose
Prepare the cluster for high availability of the Slurm controller.

### Scope
- Controller and HA nodes

### Why this order
- High-availability configuration defines controller access endpoints and shared
  state locations.
- Slurm must read this configuration before the control daemon is started.

### Skip Conditions
- A single controller is sufficient and automatic failover is not required.

### Notes
- No automatic failover in the event of controller failure.

---

### Phase 4.2: Accounting Database Setup (Optional)

### Purpose
Provide the database backend required by `slurmdbd` for job accounting.

### Scope
- Controller node or designated database host

### Why this order
- When accounting is enabled, `slurmdbd` must be able to connect to its database
  before `slurmctld` starts.
- Missing or unavailable databases can result in degraded or failed controller
  startup.

### Skip Conditions
- Detailed or long-term accounting data is not required.
- Set `slurm_accounting_enabled: false` to skip this phase.

### Notes
- Accounting tools (`sacct`, `sacctmgr`, `sreport`) are unavailable.
- Historical job accounting data is not retained.

---

### Phase 4.3: Slurm Build Prerequisites

### Purpose
Install libraries required to build Slurm from source.

### Scope
- Nodes where Slurm binaries are built (controller, compute, login)

### Installation Rationale
- Slurm is compiled and linked against these libraries (for example, hwloc and
  PMIx).
- Installing them after Slurm would require a rebuild and risks binary
  incompatibility.

---

### Phase 4.4: Slurm Core Installation and Configuration

### Purpose
Install and configure the Slurm workload manager.

### Scope
- Controller nodes
- Compute nodes
- Login-only nodes (client tools only)

### Installation Rationale
- This phase depends on:
  - Authentication and identity configuration
  - Optional database backends
  - Build-time libraries
- It forms the foundational component for all Slurm-aware tools and services.

### Operational Notes
- Login-only nodes receive Slurm binaries and configuration for client commands.
- Slurm services on login-only nodes are disabled and masked to prevent
  accidental daemon startup.

---

## Phase 5: Slurm Add-on Components

### Purpose
Install commonly used Slurm ecosystem components:
- Pyxis (container integration)
- Lmod (environment modules)
- NHC (node health checks)

### Installation Rationale
- Add-ons depend on Slurm headers, configuration files, and running daemons.
- Health checks and container plugins are meaningful only after the scheduler
  is operational.

---

## Phase 6: Software Build Tooling (EasyBuild)

### Purpose
Provide a reproducible mechanism for building and exposing software stacks to
users.

### Scope
- Designated build nodes

### Installation Rationale
- EasyBuild publishes modules through Lmod.
- Built software is typically consumed by Slurm jobs.
- Shared storage must be available to avoid partial or inconsistent
  installations.

### Operational Note
- EasyBuild is optional and disabled by default (`easybuild_enabled: false`) in `config/group_vars/slurm.yml`.
- Run the role with `--tags easybuild` and target build hosts in `[easybuild]` (or use `--limit easybuild`).

---

## Phase 7: Monitoring and Logging

### Purpose
Deploy monitoring exporters, metrics aggregation services, and centralized logging.

### Scope
- All monitored nodes
- Controller nodes
- GPU compute nodes
- Monitoring infrastructure nodes

### Installation Rationale
- Monitoring components depend on running Slurm services and, where applicable,
  GPU drivers.
- Installing monitoring last reduces false alerts and startup noise during
  initial deployment.

### Operational Note
- Monitoring/logging is optional and controlled by `monitoring_enabled`, `loki_enabled`, and `alloy_enabled` in `config/group_vars/services.yml` or your inventory.
- Disable monitoring when policy, security, or resource constraints require a
  minimal deployment.

---

## Phase 8: LDAP Server/Client (Optional)

### Purpose
Integrate centralized identity and authentication when LDAP is required.

### Scope
- LDAP server nodes (optional)
- All nodes acting as LDAP clients

### Operational Note
- LDAP roles are commented out by default in `playbooks/slurm-cluster.yml`.
- Review `docs/05-ldap.md` before enabling and running LDAP roles.

---

## Post-Installation Validation

### Purpose
Verify that:
- Slurm services are reachable
- The control plane is operational
- Nodes are ready to accept workloads

---

## Dependency summary
```
Phase 1 (Common)
  -> Phase 2 (GPU/Containers)
  -> Phase 3 (Shared storage)
  -> Phase 4 (Slurm stack)
       -> Phase 4.1 (HA prerequisites)
       -> Phase 4.2 (Accounting DB)
       -> Phase 4.3 (Hwloc/PMIx)
       -> Phase 4.4 (Slurm core)
  -> Phase 5 (Pyxis/Lmod/NHC)
       -> Phase 6 (EasyBuild)
  -> Phase 7 (Monitoring/Logging)
  -> Phase 8 (LDAP)
```
