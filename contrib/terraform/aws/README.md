<!--
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
-->

# Deploying the update server on AWS

Packer builds an AMI holding the `fioserver` release binary; Terraform deploys it
onto a single EC2 instance with a persistent EBS volume, daily snapshots, and the
server's irreplaceable secrets escrowed in AWS Secrets Manager.

Two topologies are provided:

| | `examples/with-load-balancer` | `examples/without-load-balancer` |
| --- | --- | --- |
| UI TLS | Application Load Balancer(ALB) with an ACM certificate | Caddy on the instance, Let's Encrypt |
| Device gateway | Network Load Balancer(NLB), TCP passthrough | Exposed directly on the instance |
| DNS Names | two (UI and gateway for the 2 LBs) | one |
| Extra cost | yes | no |

Both share the same modules and the same AMI.

## Why it is shaped this way

Three properties of the server drive you will deploy.

**Port 8443 must be L4 passthrough.** The device gateway terminates TLS itself
and authenticates devices by client certificate (`ClientAuth:
VerifyClientCertIfGiven`, with the device CA in `certs/cas.pem`). Terminating
that at an L7 proxy would discard the certificate the server needs, so the NLB
forwards TCP untouched.

**Terraform cannot create the TUF keys.** They are encrypted at rest with a key
derived from `auth/hmac.secret`, so they must be generated on the instance. That
turns out to be a benefit: no key material ever enters Terraform state. The
instance generates its own secrets on first boot and pushes them to Secrets
Manager using its instance profile.

**The gateway hostname is effectively immutable.** `pki-init --dnsname` becomes
the first DNS SAN of the gateway certificate, and the server derives every
device-facing URL from it — each enrolled device stores those URLs in its
`sota.toml`. Changing the name later orphans existing devices.

## Prerequisites

- Terraform >= 1.5, Packer >= 1.9, AWS CLI v2, credentials with permission to
  create VPC, EC2, ELB, IAM, Secrets Manager, DLM and (optionally) Route53
  resources.
- A Route53 hosted zone. Optional but strongly recommended: without it, `apply`
  blocks on ACM validation, and Caddy cannot obtain a certificate until DNS
  resolves.

## 1. Build the AMI

```bash
cd packer
packer init .
packer build -var fioserver_version=v0.9.2 .
```

The version is required and deliberately has no default, so an AMI is always
reproducible. Releases publish bare, uncompressed binaries
(`fioserver-linux-amd64`, `fioserver-linux-arm64`), and the build records the
version and SHA256 in `/etc/fioserver/build-info`. For Graviton, add
`-var architecture=arm64` and choose a `t4g`-class `instance_type` when deploying.

The resulting AMI ID is printed at the end and written to `packer/manifest.json`.

## 2. Deploy

```bash
cd examples/with-load-balancer
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars      # set ami_id, hostname, gateway_hostname, hosted_zone_id
terraform init
terraform apply
```

In the load-balancer topology the UI and the gateway need **separate hostnames**,
because one DNS record cannot alias to two different load balancers.

First boot then runs, in order: `auth-init`, writes `auth-config.json`,
`pki-init`, `tuf-init`, and finally escrows the results. Watch it with:

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)"
sudo journalctl -u fioserver-bootstrap -f
```

### Authentication

Leave `auth_config_json` unset and the instance configures local auth, creating
an `admin` user whose generated password is escrowed:

```bash
eval "$(terraform output -raw admin_password_command)"
```

Otherwise supply a config — see [docs/auth.md](../../../docs/auth.md) and the
`contrib/auth-config-{local,github,google}.json` templates:

```hcl
auth_config_json = <<-EOT
...
EOF
```

For OAuth providers, `Config.BaseUrl` must be `https://<hostname>` and the
provider's authorized redirect URI must be `https://<hostname>/auth/callback`.

> [!NOTE]
> A value passed through `auth_config_json` is stored in Terraform state. To keep
> an OAuth client secret out of state, leave the variable empty and populate the
> secret out of band instead:
> ```bash
> aws secretsmanager put-secret-value \
>   --secret-id "$(terraform output -raw secret_prefix)/auth-config" \
>   --secret-string file://auth-config.json
> ```

## 3. Verify

```bash
HOST=$(terraform output -raw ui_url)
curl -sI "$HOST/favicon"            # 200
curl -sI "http://${HOST#https://}"  # 301 to HTTPS
```

Then log in through a browser and open a device or update page. That exercises
the UI's own REST calls, which is the real test that `X-Forwarded-Proto` and the
self-call are both working. If those pages error, check `journalctl -u fioserver`
for attempts to reach `http://`.

To verify device mTLS, generate a device certificate against the deployed PKI and
use it (on the instance, where `/data` is the datadir).

## What is stored where

`/data` is the server's `--datadir` and the only writable location on the
instance:

```
/data/db.sqlite          devices, users, updates, sessions
/data/auth/              hmac.secret, auth-config.json
/data/certs/             tls.{key,pem}, cas.pem, root.{key,crt}, device-ca.{key,crt}
/data/tuf/               role keys and root metadata
/data/caddy/             Let's Encrypt certificates (no-load-balancer topology)
```

Secrets Manager holds, under `<name_prefix>/<hostname>/`:

| Secret | Written by | Contents |
| --- | --- | --- |
| `auth-config` | Terraform, or the instance | `auth-config.json` |
| `hmac-secret` | instance | `auth/hmac.secret`, base64 |
| `certs-archive` | instance | gzipped tar of `certs/` |
| `tuf-archive` | instance | gzipped tar of `tuf/` |
| `admin-password` | instance | generated admin password, if applicable |

Whole directories are archived rather than individual keys because a restore
needs more than the roots of trust: devices authenticate against `cas.pem` and
`device-ca.crt`, and the TUF metadata chain must match the keys. `pki-init`
cannot rebuild a partial `certs/` — it refuses to run if any file there exists.

> [!IMPORTANT]
> The escrow preserves the server's **identity**, not its **data**. `db.sqlite`
> is not in it. If the volume is lost, the PKI comes back from Secrets Manager
> but device and update records come back only from a snapshot.

## Runbooks

### Restoring onto a fresh volume

This is automatic. Boot a new instance with an empty data volume and the same
`FIOSERVER_SECRET_PREFIX`; the bootstrap detects the escrow and restores
`hmac.secret`, `auth-config.json`, `certs/` and `tuf/` byte-for-byte, so
already-enrolled devices keep working without re-enrolment.

To also recover the database, restore the most recent snapshot into a volume,
attach it, and copy `db.sqlite`, `db.sqlite-wal` and `db.sqlite-shm` into `/data`
while `fioserver` is stopped.

Check which path a boot took:

```bash
cat /data/.bootstrap-state   # "A" reboot, "B" restored, "C" initialized
```

## Backups

A Data Lifecycle Manager policy snapshots the data volume every 24 hours and
deletes snapshots older than `snapshot_retention_days` (60 by default). The
module creates its own DLM IAM role: `AWSDataLifecycleManagerDefaultRole` is
created implicitly by the AWS console but never by the API, so relying on it
makes `apply` fail on a fresh account.

> [!NOTE]
> These snapshots are crash-consistent, not application-consistent. SQLite in WAL
> mode recovers from them in practice, but a pre-snapshot `sqlite3 .backup` or
> [Litestream](https://litestream.io/) replication would be strictly better. See
> [docs/production.md](../../../docs/production.md).

## Limitations

- **One instance, one AZ.** The load balancers span two subnets because an ALB
  requires it, but there is a single instance and a single volume. The server
  keeps one SQLite database with `MaxOpenConns(1)`, so horizontal scaling is not
  available.
- **`terraform destroy` deletes the data volume.** Snapshots and the secret
  escrow are the recovery path. There is deliberately no `prevent_destroy`, since
  that would make `destroy` fail and leave the volume stranded.
- **Secrets have a recovery window.** After a destroy they sit pending deletion,
  and re-applying with the same hostname fails until they are purged or restored.
  Set `secret_recovery_window_days = 0` in throwaway environments.
