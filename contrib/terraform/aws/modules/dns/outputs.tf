# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

output "certificate_arn" {
  description = <<-EOT
    Validated ACM certificate ARN, or "" in the Caddy topology where no ACM
    certificate is used. Depends on the validation resource, so consuming this
    in a listener guarantees the certificate is issued first.
  EOT
  value       = local.want_certificate ? aws_acm_certificate_validation.ui[0].certificate_arn : ""
}

output "validation_records" {
  description = <<-EOT
    DNS validation records for the certificate. When hosted_zone_id is set these
    are created automatically; otherwise create them by hand to unblock apply.
  EOT
  value = local.want_certificate ? [
    for dvo in aws_acm_certificate.ui[0].domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ] : []
}

output "managing_dns" {
  description = "Whether this module is creating Route53 records."
  value       = local.manage_dns
}
