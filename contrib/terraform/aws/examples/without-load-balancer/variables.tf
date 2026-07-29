# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
  default     = "us-east-1"
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to resource names and tags."
  default     = "fioserver"
}

variable "hostname" {
  type        = string
  description = <<-EOT
    Public DNS name for both the UI (443) and the device gateway (8443), e.g.
    "dg.example.com".

    It must resolve to this instance's Elastic IP before Caddy can complete the
    Let's Encrypt HTTP-01 challenge. It is also baked into the gateway
    certificate and every enrolled device's configuration, so it cannot change
    later without orphaning those devices.
  EOT
}

variable "factory" {
  type        = string
  description = "Factory name recorded in the PKI subject."
}

variable "ami_id" {
  type        = string
  description = "AMI built by contrib/terraform/aws/packer."
}

variable "hosted_zone_id" {
  type        = string
  description = <<-EOT
    Route53 zone in which to create the A record for var.hostname. Leave empty
    to create it yourself -- but do so promptly, since Caddy cannot obtain a
    certificate until the name resolves.
  EOT
  default     = ""
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type."
  default     = "t3.small"
}

variable "data_volume_size" {
  type        = number
  description = "Size of the persistent /data volume in GiB."
  default     = 100
}

variable "ssh_key_name" {
  type        = string
  description = "Existing EC2 key pair, or \"\" to use SSM Session Manager only."
  default     = ""
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR allowed to reach port 22, or \"\" to omit the rule."
  default     = ""
}

variable "auth_config_json" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Contents of auth-config.json, typically `file("auth-config.json")`. Leave
    empty for local auth with a generated admin password escrowed in Secrets
    Manager. For OAuth, Config.BaseUrl must be "https://<hostname>".
  EOT
  default     = ""
}

variable "tls_expiry_days" {
  type        = number
  description = "Gateway certificate validity. The gateway will not start once it expires."
  default     = 3650
}

variable "snapshot_retention_days" {
  type        = number
  description = "Days to retain daily data-volume snapshots."
  default     = 60
}

variable "tags" {
  type        = map(string)
  description = "Extra tags applied to every resource."
  default     = {}
}
