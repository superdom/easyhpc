# Slurm Build Environment and Dependency Chain

This document is a deep dive into **Phase 4.3 (Slurm stack build prerequisites)**
and **Phase 4.4 (Slurm stack core install)** from `docs/01-installation.md`. It explains
the dependency chain, why the order matters, and how EasyHPC wires the build
environment together.

---

## Where this fits in the install sequence
- **Phase 4.3**: build prerequisites (`hwloc`, `pmix`)
- **Phase 4.4**: Slurm source build and configuration
- **Phase 2**: GPU/NVML enables extra Slurm configure flags when present
- **Phase 1**: Munge provides authentication before Slurm starts

---

## Target environment and default prefixes
- OS: RHEL 9, Ubuntu 22.04/24.04
- cgroup: v2 default
- Default install prefixes:
  - hwloc: `/opt/hpc/stack/hwloc`
  - pmix: `/opt/hpc/stack/pmix`
  - slurm: `/usr/local`

---

## Dependency chain and rationale
1) **hwloc**
   - Provides CPU/NUMA topology for binding and placement.
   - PMIx and Slurm both link against it, so it must exist first.
2) **libevent (OS package)**
   - PMIx uses it for async event handling.
3) **PMIx**
   - Enables Slurm to build `mpi_pmix` plugins for MPI runtimes.
4) **Munge**
   - Authentication layer required by Slurm daemons and `slurmdbd`.
5) **Slurm**
   - Built with `--with-hwloc` and `--with-pmix` to enable topology and PMIx
     integration.

Optional but related:
- **OpenMPI**: depends on PMIx and is typically installed after Slurm.
- **NVML**: sourced from NVIDIA drivers/CUDA to support GPU autodetect.

---

## Components: role, source, and recommended version

### hwloc
- Role: topology discovery and process binding
- Source: `https://github.com/open-mpi/hwloc`
- Install prefix: `{{ hwloc_install_prefix }}`

### libevent
- Role: PMIx async event backend
- Source: `https://github.com/libevent/libevent`
- Install method: `libevent-dev` / `libevent-devel`

### PMIx
- Role: PMI/PMIx interface between Slurm and MPI runtimes
- Source: `https://github.com/openpmix/openpmix`
- Install prefix: `{{ pmix_install_prefix }}`

### Munge
- Role: node-to-node authentication
- Source: `https://github.com/dun/munge`

### Slurm
- Role: resource allocation and job scheduling
- Source: `https://github.com/SchedMD/slurm`
- Install prefix: `{{ slurm_install_prefix }}`
- Build flags: `--with-pmix` and `--with-hwloc`

### OpenMPI (optional)
- Role: MPI API and runtime
- Source: `https://github.com/open-mpi/ompi`

### NVML (optional)
- Role: GPU state/topology for GRES autodetect
- Source: NVIDIA driver/CUDA components
- Note: used when `slurm_enable_nvml` is true

---

## How EasyHPC builds this (Ansible flow)

**Execution order**
1) `roles/hwloc`
2) `roles/pmix`
3) `roles/slurm`

**Example commands**
```
ansible-playbook -i config/inventory playbooks/slurm-cluster.yml --tags=hwloc
ansible-playbook -i config/inventory playbooks/slurm-cluster.yml --tags=pmix
ansible-playbook -i config/inventory playbooks/slurm-cluster.yml --tags=slurm
```

**Variables**
- `config/group_vars/slurm.yml`
- OS-specific build dependency defaults live in role defaults (see `roles/hwloc`, `roles/pmix`, `roles/slurm`).

---

## Build steps (summary)

### hwloc
1) Install build dependencies (`hwloc_build_dependencies`)
2) Download and extract source
3) `./configure` -> `make -j{{ hwloc_make_jobs }}` -> `make install`
4) Register `/etc/ld.so.conf.d/hwloc.conf` and run `ldconfig`

### PMIx
1) Install build dependencies (`pmix_build_dependencies`)
2) Download and extract source
3) `./configure --prefix=<pmix_install_prefix> --with-hwloc --with-libevent --with-libevent-libdir --with-munge`
4) `make -j{{ pmix_make_jobs }}` -> `make install`
5) Register `/etc/ld.so.conf.d/pmix.conf` and run `ldconfig`

### Slurm
1) Download and extract source
2) `./configure` with base options + `--with-pmix`, `--with-hwloc`
3) `make` -> `make install`
4) NVML flag added when `slurm_enable_nvml` is true

### Parallel build configuration
By default, EasyHPC uses parallel builds to speed up compilation. The number of
parallel jobs defaults to the number of CPU cores detected by Ansible
(`ansible_processor_vcpus`).

Override in `config/group_vars/slurm.yml` or inventory:
```yaml
hwloc_make_jobs: 8   # Override hwloc parallel jobs
pmix_make_jobs: 8    # Override PMIx parallel jobs
```

---

## Validation and common pitfalls
- **Build order** must remain `hwloc -> pmix -> slurm`.
- **Rebuild flags** (use when you need a clean rebuild):
  - `hwloc_force_rebuild: true`
  - `pmix_force_rebuild: true`
  - `slurm_force_rebuild: true`
- **Plugin verification**:
  - `ls {{ slurm_install_prefix }}/lib/slurm/mpi_pmix*`
  - `srun --mpi=list` should show `pmix` or `pmix_v4`
- **PATH**:
  - `pmix_info` is typically at `/opt/hpc/stack/pmix/bin/pmix_info`
- **ldconfig**:
  - Missing `ldconfig` is a common reason `mpi_pmix` fails to load
 - **Common errors**:
   - `error: while loading shared libraries: libpmix.so...` → run `ldconfig`, confirm `/etc/ld.so.conf.d/pmix.conf`.
   - `unable to load mpi/pmix` → verify PMIx install prefix and plugin path.
