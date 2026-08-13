# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

output "alb_dns_name" {
  description = "DNS name of the UI load balancer."
  value       = aws_lb.ui.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the UI load balancer, for an alias record."
  value       = aws_lb.ui.zone_id
}

output "nlb_dns_name" {
  description = "DNS name of the device gateway load balancer."
  value       = aws_lb.gateway.dns_name
}

output "nlb_zone_id" {
  description = "Hosted zone ID of the gateway load balancer, for an alias record."
  value       = aws_lb.gateway.zone_id
}
