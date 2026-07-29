# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

output "ui_url" {
  description = "Web UI address, served by Caddy with a Let's Encrypt certificate."
  value       = "https://${var.hostname}"
}

output "device_gateway_url" {
  description = "Gateway address devices connect to, exposed directly."
  value       = "https://${var.hostname}:8443"
}

output "public_ip" {
  description = "Elastic IP. Point var.hostname here if managing DNS yourself."
  value       = module.server.public_ip
}

output "instance_id" {
  description = "Instance ID, for `aws ssm start-session --target <id>`."
  value       = module.server.instance_id
}

output "data_volume_id" {
  description = "Persistent data volume ID."
  value       = module.server.data_volume_id
}

output "secret_prefix" {
  description = "Secrets Manager prefix holding the escrowed keys."
  value       = module.server.secret_prefix
}

output "admin_password_command" {
  description = "Retrieve the generated admin password (only when auth_config_json was empty)."
  value       = "aws secretsmanager get-secret-value --secret-id ${module.server.secret_prefix}/admin-password --query SecretString --output text"
}
