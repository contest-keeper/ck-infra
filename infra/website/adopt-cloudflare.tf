# One-time takeover of the Cloudflare record and Worker route an earlier deployment of this site left in the zone (same
# name, other target, for example after the Azure subscription changed). Without it the first apply of a rebuilt
# environment stops at "record already exists". They are looked up by the configured public_hostname, imported, and then
# changed in place by the normal resources. Where none exists (a new environment) nothing is imported. The old Worker
# script keeps its old name and is not touched: nothing routes to it once the route points at the new one.
# Delete this file once every environment has applied it once.

data "cloudflare_dns_records" "site_existing" {
  count   = local.proxy_site ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = { exact = var.public_hostname }
}

# This data source cannot filter by pattern, so it reads the zone's routes (a handful) and the pattern is matched below.
data "cloudflare_workers_routes" "site_existing" {
  count     = local.proxy_site ? 1 : 0
  zone_id   = var.cloudflare_zone_id
  max_items = 1000
}

locals {
  site_records = local.proxy_site ? data.cloudflare_dns_records.site_existing[0].result : []
  site_routes  = local.proxy_site ? data.cloudflare_workers_routes.site_existing[0].result : []

  # Several matches: the first is taken.
  adopt_site_record = [for r in local.site_records : r.id if r.type == "CNAME" && r.name == var.public_hostname]
  adopt_site_route  = [for r in local.site_routes : r.id if r.pattern == "${var.public_hostname}/*"]
}

import {
  for_each = toset(slice(local.adopt_site_record, 0, min(1, length(local.adopt_site_record))))
  to       = cloudflare_dns_record.site[0]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}

import {
  for_each = toset(slice(local.adopt_site_route, 0, min(1, length(local.adopt_site_route))))
  to       = cloudflare_workers_route.site[0]
  id       = "${var.cloudflare_zone_id}/${each.value}"
}
