# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

variable "name_prefix" {
  type        = string
  description = "Prefix applied to resource names and tags."
  default     = "fioserver"
}

variable "hostname" {
  type        = string
  description = <<-EOT
    Public DNS name browsers use for the UI, e.g. "dg.example.com". Also the
    name the UI resolves to loopback for its own internal API calls.
  EOT
}

variable "gateway_hostname" {
  type        = string
  description = <<-EOT
    DNS name devices use for the mTLS gateway on port 8443. Leave empty to use
    var.hostname, which is correct when one address serves both (the Caddy
    topology).

    With load balancers this MUST be a distinct name: the UI is fronted by an
    ALB and the gateway by an NLB, and a single DNS record cannot alias to both.

    This value is passed to `pki-init --dnsname` and becomes the first DNS SAN
    of the gateway certificate. The server derives every device-facing URL from
    it, and each enrolled device stores those URLs in its sota.toml -- so it is
    effectively immutable once a device has enrolled. Changing it orphans
    existing devices.
  EOT
  default     = ""
}

variable "factory" {
  type        = string
  description = "Factory name recorded in the PKI subject (`pki-init --factory`)."
}

variable "ami_id" {
  type        = string
  description = "AMI built by contrib/terraform/aws/packer."
}

variable "subnet_id" {
  type        = string
  description = "Subnet to launch the instance in."
}

variable "availability_zone" {
  type        = string
  description = "AZ for the data volume; must match the subnet's AZ."
}

variable "security_group_id" {
  type        = string
  description = "Security group for the instance."
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type."
  default     = "t3.small"
}

variable "root_volume_size" {
  type        = number
  description = "Root volume size in GiB. Holds only the OS; state lives on /data."
  default     = 8
}

variable "data_volume_size" {
  type        = number
  description = "Size of the persistent /data volume in GiB."
  default     = 100
}

variable "ssh_key_name" {
  type        = string
  description = "Existing EC2 key pair name, or \"\" to rely on SSM only."
  default     = ""
}

variable "auth_config_json" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Contents of auth-config.json, typically `file("auth-config.json")`. See
    docs/auth.md and contrib/auth-config-{local,github,google}.json; for OAuth
    providers, Config.BaseUrl must be "https://<hostname>".

    Leave empty to have the instance configure local auth on first boot and
    escrow a generated admin password in Secrets Manager.

    Note: a value set here is stored in Terraform state. To keep an OAuth client
    secret out of state, leave this empty and populate the auth-config secret
    out of band with `aws secretsmanager put-secret-value`.
  EOT
  default     = ""
}

variable "tls_expiry_days" {
  type        = number
  description = <<-EOT
    Validity of the gateway TLS certificate, in days.

    Deliberately long. The gateway REFUSES TO START once this certificate
    expires, and nothing renews it automatically -- Caddy's Let's Encrypt
    automation covers only the UI port. `pki-init` itself defaults to 365, which
    would turn a working deployment into a hard failure a year later.
  EOT
  default     = 3650
}

variable "enable_caddy" {
  type        = bool
  description = "Run Caddy on the instance for TLS (the no-load-balancer topology)."
  default     = false
}

variable "assign_eip" {
  type        = bool
  description = <<-EOT
    Attach an Elastic IP. Required for the Caddy topology: the address is baked
    into the TLS certificate and into every device's configuration, so it must
    not change when the instance stops.
  EOT
  default     = false
}

variable "enable_ssm" {
  type        = bool
  description = "Attach AmazonSSMManagedInstanceCore for Session Manager access."
  default     = true
}

variable "snapshot_retention_days" {
  type        = number
  description = "Days to retain daily data-volume snapshots before deletion."
  default     = 60
}

variable "snapshot_start_time" {
  type        = string
  description = "UTC time of day for the daily snapshot, as HH:MM."
  default     = "05:17"
}

variable "secret_recovery_window_days" {
  type        = number
  description = <<-EOT
    Secrets Manager recovery window. Note that a non-zero value means a
    destroyed stack leaves secrets pending deletion, and re-applying with the
    same name fails until they are purged or restored.
  EOT
  default     = 7
}

variable "tags" {
  type        = map(string)
  description = "Extra tags applied to every resource."
  default     = {}
}
