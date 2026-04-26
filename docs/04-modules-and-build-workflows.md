# Modules and Build Workflows (EasyBuild + Lmod)

This guide expands **Phase 5 (Slurm add-ons)** and **Phase 6 (Software build
tooling)** from `docs/01-installation.md`. It explains *why* Lmod and EasyBuild
must be installed in that order, how shared paths are used, and how to verify a
module build end-to-end in a Slurm job.

---

## Where this fits in the install sequence
- **Phase 5**: Lmod is installed after Slurm so job environments can load modules.
- **Phase 6**: EasyBuild depends on Lmod and uses the shared module tree.

---

## Design principles
- **Modules are shared**: users should see the same module tree from login and
  compute nodes.
- **Builds are reproducible**: EasyBuild uses a single configuration file and
  deterministic paths.
- **Slurm jobs are the consumer**: validation uses `sbatch` to confirm runtime
  visibility and paths.

---

## Prerequisites
- Shared storage is available and mounted on all nodes where modules are used.
- Lmod is enabled (`lmod_enabled: true`). Configure it in `config/group_vars/slurm.yml` or your inventory.
- EasyBuild is disabled by default (`easybuild_enabled: false`). Enable it in `config/group_vars/slurm.yml` when you are ready to build software.
- The shared module tree is consistent with your storage choice (defined in `config/group_vars/all.yml`):
  - `modules_base_path`: root directory for all module-related files (default: `{{ shared_storage_mount }}/apps`)
  - `modules_root`: alias for `modules_base_path`
  - `modules_path`: where Lmod module files are stored (default: `{{ modules_root }}/modules/all`)
  - `modules_storage_path`: where EasyBuild installs software (default: `{{ modules_root }}`)
  - `modules_storage_host`: host that manages shared module storage
  - `modules_manage_shared_paths`: set to `false` if you manage shared paths externally

**Required vs optional**
- **Required**: shared storage mount, `lmod_enabled: true`, module tree paths.
- **Optional**: EasyBuild (`easybuild_enabled: true`) and a dedicated `[easybuild]` host.

---

## Installation order and rationale

### 1) Lmod first
**Why**
- EasyBuild writes module files; Lmod must exist to manage them.
- Slurm job environments rely on `MODULEPATH` being stable.

**Outcome**
- `MODULEPATH` includes the shared module tree.
- Module files created by EasyBuild are discoverable on all nodes.

### 2) EasyBuild second
**Why**
- EasyBuild uses Lmod as its module tool and writes to shared paths.
- It is the build system that populates the module tree used by jobs.

**Outcome**
- Software stacks appear as modules under the shared prefix.
- Builds can be reused by all nodes without local installs.

---

## Deploy the EasyBuild role
**Target hosts**
- Ensure build hosts are in the `easybuild` inventory group (or select a host
  group explicitly).

**Variables to confirm**
- `easybuild_enabled: true`
- Shared paths: `modules_base_path`, `modules_root`, `modules_path`
- Build/temp paths: defaults use local `/tmp` for speed

**Run**
- `ansible-playbook -i config/inventory playbooks/slurm-cluster.yml --tags easybuild --limit easybuild`

**Activation**
- After deployment, re-login or run:
  `source /etc/profile.d/easybuild.sh`

---

## Validate module visibility
```bash
echo $MODULEPATH
module avail EasyBuild
module load EasyBuild
```

Check EasyBuild configuration:
```bash
eb --show-config | egrep 'installpath|modulepath|buildpath|tmpdir|sourcepath|repositorypath|robot-paths'
cat <shared_path>/easybuild/config/eb.cfg
```

Expected:
- install path points to the shared prefix
- modules path points to the shared module tree

---

## Example build (Miniconda3)
Search for an easyconfig:
```bash
eb --search Miniconda3
```

Build:
```bash
eb Miniconda3-25.7.0-2.eb --robot
```

Verify module availability:
```bash
module avail Miniconda3
```

---

## End-to-end validation in a Slurm job
Example `module-test.sh` (replace `<shared_path>` with your shared prefix).
Run from a **login node** (or any node with `sbatch` access):
```bash
#!/bin/bash
#SBATCH -J module-check
#SBATCH -o module-check.out
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:05:00

module purge
module load Core/Miniconda3/25.7.0-2

echo "== hostname: $(hostname)"
echo "== conda info:"
conda info
```

Submit and verify:
```bash
sbatch module-test.sh
squeue
cat module-check.out
```

---

## Common pitfalls
- **Missing shared mount**: modules appear on the build host only.
- **Wrong module path**: `MODULEPATH` not updated, `module avail` appears empty.
- **Mixed prefixes**: EasyBuild writes to a different path than Lmod reads.

---

## Related documents
- `docs/01-installation.md`
- `docs/03-slurm-build-environment.md`
