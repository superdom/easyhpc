# Firewall Setup Guide (EasyHPC)

This document explains *which ports must be open and why*, and how the firewall
rules map to the EasyHPC installation phases in `docs/01-installation.md`.

**Note**: EasyHPC disables firewalld/UFW during installation by default
(`firewall_enabled: false` in `roles/common/defaults/main.yml`). Use this guide
for post-install hardening. If you want to keep the firewall enabled during
deployment, set `firewall_enabled: true` in your group vars.

---

## Where this fits in the install sequence
- **Phase 1 (Common baseline)**: SSH reachable for automation.
- **Phase 3 (Shared storage)**: NFS ports only if NFS is enabled.
- **Phase 4.4 (Slurm core)**: Controller/compute RPC ports for scheduling.
- **Phase 7 (Monitoring/Logging)**: Prometheus/Grafana/exporters/Loki ports when enabled.

---

## Port matrix (by service)
Open only what you use. If a phase is disabled, close the related ports.

| Service | Port | Proto | Purpose |
|--------|------|-------|---------|
| SSH | 22 | TCP | Remote access, Ansible control |
| Slurmctld | 6817 | TCP | Controller RPC |
| Slurmd | 6818 | TCP | Compute daemon RPC |
| slurmdbd | 6819 | TCP | Accounting daemon |
| MariaDB/MySQL | 3306 | TCP | Accounting database |
| NFS | 2049 | TCP/UDP | Shared storage |
| Prometheus | 9090 | TCP | Metrics store |
| Grafana | 3000 | TCP | Dashboards |
| Loki | 3100 | TCP | Log store |
| Node Exporter | 9100 | TCP | Node metrics |
| Slurm Exporter | 8080 | TCP | Slurm metrics |
| DCGM Exporter | 9400 | TCP | GPU metrics |
| Alertmanager | 9093 | TCP | Alert routing |
| Alloy | 12345 | TCP | Log agent (localhost-only by default) |

---

## Role-based guidance
**Controller nodes**
- Open: 22/TCP, 6817/TCP
- If accounting enabled: 6819/TCP (slurmdbd), 3306/TCP (DB host)
- If monitoring enabled: 8080/TCP

**Compute nodes**
- Open: 22/TCP, 6818/TCP
- If GPUs + monitoring enabled: 9400/TCP
- If using configless Slurm with `--conf-server`, allow outbound TCP 6817
  to the controllers so `slurmd` can fetch config.

**Login nodes**
- Open: 22/TCP
- Slurm services are masked on login-only nodes, but client commands still use
  the controller port (outbound).

**All managed nodes**
- If node_exporter_enabled (default): 9100/TCP

**NFS server/client**
- Open: 2049/TCP+UDP (and any additional NFS services you use)

**Monitoring node**
- Open: 9090/TCP, 3000/TCP, 9093/TCP
- Plus exporter ports if this node also scrapes or runs Slurm exporters

**Logging node**
- Open: 3100/TCP

---

## firewalld (RHEL/CentOS/Rocky/Alma)
Enable and add core ports:
```bash
systemctl enable firewalld
systemctl start firewalld

firewall-cmd --permanent --add-port=6817/tcp
firewall-cmd --permanent --add-port=6818/tcp
firewall-cmd --permanent --add-port=3100/tcp

firewall-cmd --reload
firewall-cmd --list-all
```

**Accounting (slurmdbd + DB)**
```bash
firewall-cmd --permanent --add-port=6819/tcp
firewall-cmd --permanent --add-port=3306/tcp
firewall-cmd --reload
```

**Optional services**
```bash
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=nfs
firewall-cmd --reload
```

**Restrict by source (recommended)**
```bash
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port protocol="tcp" port="6817" accept'
firewall-cmd --reload
```

---

## UFW (Ubuntu)
Enable and add core ports:
```bash
ufw allow ssh
ufw allow 6817/tcp
ufw allow 6818/tcp
ufw allow 3100/tcp

ufw enable
ufw status verbose
```

**Accounting (slurmdbd + DB)**
```bash
ufw allow 6819/tcp
ufw allow 3306/tcp
```

---

## Internal cluster traffic
**Why**
- Slurm RPC must flow between controller and compute nodes.
- Exporters must be reachable from Prometheus.

Example (firewalld rich rules):
```bash
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.10" port protocol="tcp" port="6818" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" destination address="192.168.1.10" port protocol="tcp" port="6817" accept'
firewall-cmd --reload
```

---

## Validation and troubleshooting
**Required checks**
- Confirm expected ports are listening:
```bash
ss -tuln
```

**Optional checks**
- Test connectivity (from a client or node in the same subnet):
```bash
nc -zv controller.example.com 6817
nc -zv compute01.example.com 6818
```

**Service state**
```bash
firewall-cmd --list-all
journalctl -u firewalld
```

**UFW state**
```bash
ufw status verbose
```

---

## Best practices
- Open only the ports required by enabled phases.
- Restrict sources to the cluster management subnet.
- Keep a documented change log for firewall rules.

---

## References
- https://firewalld.org/documentation/
- https://help.ubuntu.com/community/UFW
