# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, in the order the AZs were given."
  value       = aws_subnet.public[*].id
}

output "server_security_group_id" {
  description = "Security group attached to the update server instance."
  value       = aws_security_group.server.id
}

output "alb_security_group_id" {
  description = "Security group for the ALB (unused in the Caddy topology)."
  value       = aws_security_group.alb.id
}
