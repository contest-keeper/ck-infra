# One-time takeover of the Cloudflare records an earlier deployment of this Hub left in the zone (same names, other
# values, for example after the Azure subscription changed). Without it the first apply of a rebuilt environment
# stops at "record already exists". The records are looked up by their exact names, imported, and then changed in
# place by the normal resources. Where no record exists (production, a new environment) nothing is imported.
# Delete this file once every environment has applied it once.

locals {
  # Azure fixes the two DKIM selector names for a customer-managed domain; the other names come from the variables.
  adopt_names = toset(concat(
    local.manage_dns ? [var.custom_domain, "asuid.${var.custom_domain}"] : [],
    local.mail ? [
      var.mail_domain,
      "selector1-azurecomm-prod-net._domainkey.${var.mail_domain}",
      "selector2-azurecomm-prod-net._domainkey.${var.mail_domain}",
    ] : [],
  ))
}

# One lookup per exact name, so no result list is cut short.
data "cloudflare_dns_records" "existing" {
  for_each = local.adopt_names
  zone_id  = var.cloudflare_zone_id
  name     = { exact = each.key }
}

locals {
  existing = flatten([for lookup in data.cloudflare_dns_records.existing : lookup.result])

  # Each key is the record the normal resource makes. Several matches for one key: the first is taken.
  adopt_hub_cname        = [for r in local.existing : r.id if r.type == "CNAME" && r.name == var.custom_domain]
  adopt_hub_verification = [for r in local.existing : r.id if r.type == "TXT" && r.name == "asuid.${var.custom_domain}"]
  adopt_mail_groups = {
    "txt-domain" = [for r in local.existing : r.id if r.type == "TXT" && r.name == var.mail_domain && can(regex("^\"?ms-domain-verification=", r.content))]
    "txt-spf"    = [for r in local.existing : r.id if r.type == "TXT" && r.name == var.mail_domain && can(regex("^\"?v=spf1", r.content))]
    "dkim"       = [for r in local.existing : r.id if r.type == "CNAME" && r.name == "selector1-azurecomm-prod-net._domainkey.${var.mail_domain}"]
    "dkim2"      = [for r in local.existing : r.id if r.type == "CNAME" && r.name == "selector2-azurecomm-prod-net._domainkey.${var.mail_domain}"]
  }
  adopt_mail = { for key, ids in local.adopt_mail_groups : key => ids[0] if length(ids) > 0 }
}

import {
  for_each = toset(slice(local.adopt_hub_cname, 0, min(1, length(local.adopt_hub_cname))))
  to       = cloudflare_dns_record.hub_cname[0]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}

import {
  for_each = toset(slice(local.adopt_hub_verification, 0, min(1, length(local.adopt_hub_verification))))
  to       = cloudflare_dns_record.hub_verification[0]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}

import {
  for_each = local.adopt_mail
  to       = cloudflare_dns_record.mail[each.key]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}
