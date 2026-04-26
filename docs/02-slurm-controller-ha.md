# Slurm Controller HA Guide (EasyHPC)

This document explains how EasyHPC configures **Slurm controller (slurmctld)
high availability** and why the steps are ordered the way they are. The design
follows the SchedMD HA guidance:

- SchedMD Quick Start Admin Guide - High Availability:
  `https://slurm.schedmd.com/quickstart_admin.html#HA`

## Goals and scope
**Goal**
- Run `slurmctld` across **two or more controller nodes** in **Active/Standby**
  mode, with automatic promotion of a backup on primary failure.

**In scope**
- `slurmctld` HA using `SlurmctldHost` and a shared `StateSaveLocation`.

**Out of scope (separate work)**
- MariaDB/MySQL HA
- `slurmdbd` HA
- VIP/load balancers/fencing

---

## Quick checklist (before you start)
- At least **two** hosts in `[slurm-controller]`
- Shared storage mounted at the same path on all controllers
- Same Slurm version + identical `munge.key`
- Healthy time sync (chrony/NTP)

## SchedMD HA summary (design rationale)
SchedMD identifies two requirements as the foundation of `slurmctld` HA:

1) **Multiple `SlurmctldHost` entries** in `slurm.conf`
   - First host is primary; subsequent hosts are backups.
   - On failure, a backup promotes itself to primary.
   - On recovery, the original primary can rejoin using the shared state.

2) **Shared `StateSaveLocation`** across controllers
   - Controllers read and write the same state directory on shared storage.
   - This is the key to fast recovery with minimal state loss.

Optional hooks can be used when external orchestration is required:
- `SlurmctldPrimaryOnProg`: run when a node becomes primary.
- `SlurmctldPrimaryOffProg`: run when a node steps down.

**Configless note (compute nodes)**
- If you use configless Slurm, compute nodes should start `slurmd` with
  `--conf-server` pointing to the HA controllers, for example:
  `slurmd --conf-server=easyhpc-mgmt01:6817,easyhpc-mgmt02:6817`.
- This pairs with `SlurmctldParameters=enable_configless` on the controllers.
- See `docs/01-installation.md` (Phase 4) for the full configless checklist.

---

## How EasyHPC implements slurmctld HA

### 1) Variables and policy
Defined in `config/group_vars/slurm.yml` (can override defaults from `roles/ha-slurm/defaults/main.yml`):
- `ha_enabled`: HA request toggle. **Default**: `false` (single-controller mode) in `roles/ha-slurm/defaults/main.yml`.
- `slurm_ha_enabled`: derived HA toggle used by roles (defaults to `ha_enabled`).
- `slurmctld_hosts`: list of controllers (defaults to `[slurm-controller]`).
- `slurm_state_save_location_single`: local state path for single-controller.
- `slurm_state_save_location_ha`: shared path for HA.
- `slurm_state_save_location`: selected based on `slurm_ha_enabled`.

`slurm_config.StateSaveLocation` is derived from
`slurm_state_save_location`, so the path is rendered into `slurm.conf`.

### 2) Orchestration gate
`playbooks/slurm-cluster.yml` runs the `ha-slurm` role when
`slurm_ha_enabled` is true. This role validates prerequisites (controller count,
shared storage, mount availability) before any services start.

### 3) `slurm.conf` rendering
`roles/slurm/templates/slurm.conf.j2` outputs:
- Multiple `SlurmctldHost=` lines when HA is enabled and controller count >= 2.
- A single `SlurmctldHost=` otherwise.

### 4) State directory setup
Controller nodes create `StateSaveLocation` and set ownership before
`slurmctld` starts.

### 5) Safety: no state wipe in HA
In HA mode, EasyHPC **skips** any cleanup that would delete
`StateSaveLocation`, preventing a shared state wipe across controllers.

---

## Deployment sequence and rationale

### Step 0. Verify prerequisites
**Why first**
- HA depends on shared state and consistent auth. If these fail, promotion
  behavior becomes undefined or unsafe.

**Checklist**
- At least **two controller nodes**.
- Same Slurm version and `munge.key` on both controllers.
- Time sync (chrony/NTP) is healthy.
- Shared storage is mounted on the controllers at the same path.

---

### Step 1. Define the controller set in inventory
**Why now**
- HA uses the `[slurm-controller]` group to build `SlurmctldHost` entries.
- Any controller not listed here will not participate in HA.

In `config/inventory`, list both controllers:

```ini
[slurm-controller]
easyhpc-mgmt01 ansible_host=10.0.128.11
easyhpc-mgmt02 ansible_host=10.0.128.12
```

---

### Step 2. Provide shared storage for state
**Why now**
- The shared `StateSaveLocation` must be mounted before Slurm starts or failover
  will not preserve controller state.

Configure shared storage in `config/group_vars/all.yml`:
- Set `shared_storage_mount` (default: `/data`) to your shared mount root.
- For internal NFS, keep `nfs_enable_server: true` and `nfs_enable_client: true` in
  `config/group_vars/all.yml`, and confirm `nfs_mounts` matches your mount root.
- For external storage, set `nfs_enable_server: false` and `nfs_enable_client: false`
  (or `nfs_mounts: []`) and ensure the external path is already mounted on controllers.

Validate on controllers:
- `findmnt -T <slurm_state_save_location_ha>` resolves to a mounted filesystem
  (not `/`).

**Operational note**
- If the shared mount uses `root_squash`, the root of the mount may be
  non-writable. EasyHPC pre-creates the `.slurm_state` directory with `slurm`
  ownership and `0700` permissions to avoid this failure mode.

---

### Step 3. Enable HA and set the shared state path
**Why now**
- `slurm_state_save_location_ha` must be set before `slurm.conf` is rendered.

In `config/group_vars/slurm.yml`:
```yaml
ha_enabled: true
slurm_state_save_location_ha: "/data/.slurm_state"
```
Ensure the path lives on your shared storage mount.

---

### Step 4. Keep MariaDB single-node (recommended)
**Why now**
- EasyHPC only deploys `slurm-mysql` on `groups['slurm-controller'][0]`. You
  should plan for a single DB host unless you have a dedicated HA design.

**Note**
- Keeping DB HA separate avoids coupling failure domains and simplifies
  troubleshooting.

---

### Step 5. Run the deployment
```bash
ansible-playbook -i config/inventory playbooks/slurm-cluster.yml
```

If prerequisites are missing, the `ha-slurm` role will fail with explicit
assertions.

---

### Step 6. Validate the result
On each controller:
- `StateSaveLocation` resolves to the shared path.
- `slurm.conf` contains two or more `SlurmctldHost=` lines.
- One controller is active; the other is standby.

Example commands:
```bash
scontrol ping
scontrol show config | rg -n "SlurmctldHost|StateSaveLocation"
```

---

## Failover behavior (expected flow)
For two controllers (`server1`, `server2`):

1) Normal: `server1` is primary, `server2` is standby.
2) `server1` failure: `server2` promotes itself to primary.
3) `server1` recovery: `server1` re-reads shared state and `server2` returns to
   standby.

The shared `StateSaveLocation` enables both controllers to read the same state
and continue scheduling with minimal disruption.

### Failover delay (important)
**Warning**
Promotion is not instantaneous. During detection and promotion, the standby
controller refuses RPCs and users may see `sinfo`/`squeue` appear to hang.

Indicators in `slurmctld.log`:
- Standby refusal: `Invalid RPC received ... while in standby mode`
- Promotion: `... taking over` and `Running as primary controller`

For planned maintenance, use `scontrol takeover` on the backup before stopping
the primary to minimize downtime.

---

## When to use SlurmctldPrimaryOnProg/OffProg
These hooks are optional. Use them when external actions must track the primary
controller:
- Moving a VIP, DNS, or cloud ENI to the active controller.
- Running a service that should only run on the primary.

---

## MariaDB and accounting HA (separate design)
This guide keeps MariaDB single-node by design.
- `slurm-mysql` runs only on `groups['slurm-controller'][0]`.
- Accounting remains a single point of failure (SPOF) unless you add a dedicated DB HA solution.

SchedMD mentions the following mechanisms for accounting HA:
- `AccountingStorageBackupHost` in `slurm.conf`
- `DbdBackupHost` in `slurmdbd.conf`
- Two `slurmdbd` instances sharing a DB backend

Treat DB HA as a separate project (Galera, RDS Multi-AZ, Pacemaker, managed DB).

---

## Operational checklist
- Both controllers use the same `munge.key`.
- Both controllers mount the same `StateSaveLocation`.
- Perform a controlled failover test:
  - `systemctl stop slurmctld` on the primary
  - verify promotion on the backup
  - restore the original primary and confirm steady state

---

## References
- `https://slurm.schedmd.com/quickstart_admin.html#HA`
