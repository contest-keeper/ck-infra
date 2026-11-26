# One-time takeover of the Cloudflare records an earlier deployment of this Hub left in the zone (same names, other
# values, for example after the Azure subscription changed). Without it the first apply of a rebuilt environment
# stops at "record already exists". The records are found by the configured domains, imported, and then changed in
# place by the normal resources. Where no record exists (production, a new environment) nothing is imported.
# Delete this file once every environment has applied it once.

data "cloudflare_dns_records" "hub_existing" {
  count     = local.manage_dns ? 1 : 0
  zone_id   = var.cloudflare_zone_id
  name      = { endswith = var.custom_domain }
  max_items = 100
}

data "cloudflare_dns_records" "mail_existing" {
  count     = local.mail ? 1 : 0
  zone_id   = var.cloudflare_zone_id
  name      = { endswith = var.mail_domain }
  max_items = 100
}

locals {
  hub_existing  = local.manage_dns ? data.cloudflare_dns_records.hub_existing[0].result : []
  mail_existing = local.mail ? data.cloudflare_dns_records.mail_existing[0].result : []

  adopt_hub_cname        = [for r in local.hub_existing : r.id if r.type == "CNAME" && r.name == var.custom_domain]
  adopt_hub_verification = [for r in local.hub_existing : r.id if r.type == "TXT" && r.name == "asuid.${var.custom_domain}"]

  # The two TXT records at the mail domain are told apart by their content; the two DKIM keys are the two CNAMEs,
  # taken in name order (Azure's selector1 sorts before selector2), as in cloudflare_dns_record.mail.
  mail_cname_names = sort([for r in local.mail_existing : r.name if r.type == "CNAME"])
  adopt_mail = merge(
    { for r in local.mail_existing : "txt-spf" => r.id if r.type == "TXT" && r.name == var.mail_domain && can(regex("v=spf1", r.content)) },
    { for r in local.mail_existing : "txt-domain" => r.id if r.type == "TXT" && r.name == var.mail_domain && !can(regex("v=spf1", r.content)) },
    { for r in local.mail_existing : "dkim" => r.id if r.type == "CNAME" && length(local.mail_cname_names) > 0 && r.name == local.mail_cname_names[0] },
    { for r in local.mail_existing : "dkim2" => r.id if r.type == "CNAME" && length(local.mail_cname_names) > 1 && r.name == local.mail_cname_names[1] },
  )
}

import {
  for_each = toset(local.adopt_hub_cname)
  to       = cloudflare_dns_record.hub_cname[0]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}

import {
  for_each = toset(local.adopt_hub_verification)
  to       = cloudflare_dns_record.hub_verification[0]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}

import {
  for_each = local.adopt_mail
  to       = cloudflare_dns_record.mail[each.key]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}
