# LDAP Integration Guide (OpenLDAP + SSSD)

This document explains how to deploy an OpenLDAP server and SSSD-based LDAP
clients in EasyHPC, with TLS enabled. It keeps the original behavior and steps
but uses the same structure as the installation docs.

## Where this fits in the install sequence
- **After Phase 1** (`docs/01-installation.md`): system users, time sync, and
  base OS config must exist before you enable LDAP logins.
- **After Phase 3** if you use shared home directories (NFS/EFS/etc).
- The LDAP roles are **not enabled by default** in
  `playbooks/slurm-cluster.yml`; complete the prerequisites below, then
  un-comment them or run with explicit tags.

---

## Goals and scope
**Goal**
- Centralize user and group identity across the cluster using OpenLDAP
  (server) and SSSD (clients).

**In scope**
- Single OpenLDAP server
- TLS setup
- Base DIT seeding
- Optional password policy (ppolicy)

**Out of scope**
- LDAP HA / replication / failover (syncrepl)
- External directory integration (FreeIPA/AD)

---

## Prerequisites
- OpenSSL 1.1.1+ (for `-addext`)
- TLS assets created on the controller and copied by Ansible
- CA private key stored offline (never copied to the LDAP server)
- Stable hostnames and IPs for the LDAP server

---

## Quick start summary
1) Generate CA + server certs (TLS)
2) Point EasyHPC to the TLS files in `config/group_vars/ldap.yml`
3) Set root/bind credentials in `config/group_vars/ldap.yml`
4) Run LDAP roles with `--tags ldap-server,ldap-client`
5) Validate TLS + bind and create a test user

## EasyHPC implementation
**Roles**
- `ldap-server`: OpenLDAP install, TLS files, schema load, base DIT seed
- `ldap-client`: SSSD config, CA trust, NSS/PAM integration

**Variables**
- `config/group_vars/ldap.yml`

---

## Deployment sequence and rationale

### Step 1. Generate CA and server certificates
**Why first**
- TLS assets must exist before the roles can deploy them to the server and
  clients.

Create a working directory on the controller:
```bash
mkdir -p /home/ec2-user/tls
cd /home/ec2-user/tls
```

Create an encrypted CA key and root certificate:
```bash
openssl genrsa -aes256 -out easyhpc_ca.key 2048

openssl req -x509 -new -key ./easyhpc_ca.key -sha256 -days 3650 \
  -subj "/CN=easyhpc-root-ca" \
  -addext "basicConstraints=critical,CA:true" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out easyhpc_ca.pem
```

Create the LDAP server key:
```bash
openssl genrsa -out ldap_server.key 2048
```

Create a SAN config and CSR:
```text
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no

[dn]
CN = easyhpc-mgmt03

[v3_req]
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = easyhpc-mgmt03
IP.1  = 10.0.128.13
```

```bash
openssl req -new -key ldap_server.key -out ldap_server.csr -config san.cnf
```

Sign the server certificate with the CA:
```bash
openssl x509 -req -in ldap_server.csr -CA easyhpc_ca.pem -CAkey easyhpc_ca.key \
  -CAcreateserial -out ldap_server.pem -days 825 -sha256 \
  -extfile san.cnf -extensions v3_req
```

---

### Step 2. Point EasyHPC to the TLS files
**Why now**
- The LDAP roles copy these files to the server and clients.

In `config/group_vars/ldap.yml`:
```yaml
ldap_tls_enabled: true

ldap_tls_cert_src: "/home/ec2-user/tls/ldap_server.pem"
ldap_tls_key_src: "/home/ec2-user/tls/ldap_server.key"
ldap_tls_ca_cert_src: "/home/ec2-user/tls/easyhpc_ca.pem"
```

**TLS file placement (by OS)**
| OS | Server cert | Server key | CA anchor |
| --- | --- | --- | --- |
| RHEL/Rocky | `/etc/openldap/certs/ldap_server.pem` | `/etc/openldap/certs/ldap_server.key` | `/etc/pki/ca-trust/source/anchors/easyhpc_ca.pem` |
| Ubuntu | `/etc/ssl/certs/ldap_server.pem` | `/etc/ssl/private/ldap_server.key` | `/usr/local/share/ca-certificates/easyhpc_ca.pem` |

**Security note**
- Do **not** copy the CA private key to any cluster node.

---

### Step 3. Set LDAP root and bind credentials
**Why now**
- DIT seeding and client binds depend on consistent plaintext and hashed
  credentials.

Generate hashes:
```bash
slappasswd -s 'your_password_here'
```

In `config/group_vars/ldap.yml`:
```yaml
ldap_root_pw: "your_password_here"
ldap_root_pw_hash: "{SSHA...}"

ldap_bind_pw: "your_password_here"
ldap_bind_pw_hash: "{SSHA...}"
```

SSSD uses the bind account (default:
`cn=ldap-bind,ou=ServiceAccounts,...`), not the admin DN.

---

### Step 4. Run the LDAP roles
**Why now**
- TLS assets and credentials must be in place before the server is seeded and
  clients bind.

The roles are commented out in
`playbooks/slurm-cluster.yml`. Uncomment them, then run with tags:
```bash
ansible-playbook -i config/inventory playbooks/slurm-cluster.yml \
  --tags ldap-server,ldap-client
```

**Client trust**
- If `ldap_tls_ca_cert_content` is set, the client role deploys the CA and
  enables TLS validation.

---

### Step 5. Verify TLS and bind
Confirm the certificate contains SAN and key usage:
```bash
openssl x509 -in ./ldap_server.pem -noout -text | \
  grep -A3 -E "Subject Alternative Name|Key Usage"
```

---

## User management

### Home directory policy
EasyHPC uses `ldap_home_prefix` (in `config/group_vars/ldap.yml`) to build home
paths:
- Shared storage: `{{ shared_storage_mount }}/users`

**Recommended**
1) Set LDAP `homeDirectory` to `/data/users/<userid>` (or your shared prefix).
2) Pre-create the directories on the NFS server with matching UID/GID.

If you need to override LDAP paths on the client side:
```yaml
ldap_override_homedir_enabled: true
ldap_override_homedir: "/data/users/%u"
```

**Note**
- With `root_squash`, automatic home creation on clients can fail. Create
  homes on the NFS server instead.

---

### Allow users to change their own passwords (ACL)
**Why**
- `passwd` should update `userPassword` in LDAP, which requires a self-write
  ACL.

Find the correct DB DN:
```bash
sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=config \
  '(objectClass=olcDatabaseConfig)' dn olcSuffix
```

Create `/tmp/acl.ldif` with the real `{X}` and suffix:
```ldif
dn: olcDatabase={X}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by dn.exact="cn=admin,dc=example,dc=com" write by * none
olcAccess: {1}to dn.subtree="ou=People,dc=example,dc=com" by dn.exact="cn=ldap-bind,ou=ServiceAccounts,dc=example,dc=com" read by self read by dn.exact="cn=admin,dc=example,dc=com" write by * none
olcAccess: {2}to dn.subtree="ou=Groups,dc=example,dc=com" by dn.exact="cn=ldap-bind,ou=ServiceAccounts,dc=example,dc=com" read by dn.exact="cn=admin,dc=example,dc=com" write by * none
olcAccess: {3}to dn.base="dc=example,dc=com" by * read
-
```

Apply and verify:
```bash
sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /tmp/acl.ldif
sudo ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b 'olcDatabase={X}mdb,cn=config' olcAccess
```

---

### Force password change on next login (ppolicy)
**Why**
- `ppolicy` can enforce password change on first login or after reset.

**Notes**
- `{X}` must match the database number from the ACL step.
- Module name may be `ppolicy.so` or `ppolicy.la` depending on the distro.
- Clients must set `ldap_pwd_policy: ppolicy` in `config/group_vars/ldap.yml`.

**Summary flow**
1) Load the module
2) Add the overlay
3) Create the default policy
4) Mark a user with `pwdReset: TRUE`

Example LDIFs (adjust suffix and DN):
```ldif
dn: cn=module{0},cn=config
objectClass: olcModuleList
cn: module
olcModuleLoad: ppolicy.la
```

```ldif
dn: olcOverlay=ppolicy,olcDatabase={X}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
olcPPolicyDefault: cn=default,ou=Policies,dc=example,dc=com
olcPPolicyHashCleartext: TRUE
olcPPolicyForwardUpdates: FALSE
```

```ldif
dn: ou=Policies,dc=example,dc=com
objectClass: top
objectClass: organizationalUnit
ou: Policies

dn: cn=default,ou=Policies,dc=example,dc=com
objectClass: top
objectClass: device
objectClass: pwdPolicy
cn: default
pwdAttribute: userPassword
pwdMustChange: TRUE
pwdMaxAge: 0
pwdExpireWarning: 0
pwdInHistory: 0
pwdCheckQuality: 0
```

```ldif
dn: uid=testuser,ou=People,dc=example,dc=com
changetype: modify
add: pwdReset
pwdReset: TRUE
```

---

### Add a test user
Example LDIF:
```ldif
dn: uid=testuser,ou=People,dc=example,dc=com
objectClass: top
objectClass: posixAccount
objectClass: inetOrgPerson
cn: Test User
sn: User
uid: testuser
uidNumber: 20001
gidNumber: 20000
homeDirectory: /data/users/testuser
loginShell: /bin/bash
userPassword: testuser
pwdReset: TRUE
```

Apply:
```bash
ldapadd -x -D "cn=admin,dc=example,dc=com" -w "<ldap_root_pw>" -H ldapi:/// \
  -f /tmp/testuser.ldif

ldappasswd -x -D "cn=admin,dc=example,dc=com" -w "<ldap_root_pw>" \
  "uid=testuser,ou=People,dc=example,dc=com" -S
```

Verify on a client:
```bash
getent passwd testuser
```

---

## Troubleshooting
- `ldap_add: Invalid syntax (21) ... uidNumber`: ensure numeric UID/GID values.
- `getent passwd <user>` empty: SSSD cannot bind; verify `ldap_bind_dn`,
  `ldap_bind_pw`, then restart `sssd`.
- Password prompt loops: `ldap_default_authtok` set to a hash instead of
  plaintext.
- `passwd` fails with `Insufficient access (50)`: missing self-write ACL for
  `userPassword`.
- ACL applied but lookups fail: ensure the bind DN has read access to
  `ou=People` and `ou=Groups`.
