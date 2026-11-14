# The site is plain files, so it is served from a storage account's static website endpoint. Azure Static
# Web Apps is not used because its regions are not allowed on the subscription this runs in.

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

resource "azurerm_storage_account" "site" {
  name                            = "${var.name}${random_string.suffix.result}"
  resource_group_name             = data.azurerm_resource_group.this.name
  location                        = data.azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_account_static_website" "site" {
  storage_account_id = azurerm_storage_account.site.id
  index_document     = "index.html"
  error_404_document = "index.html"
}

# ---------------------------------------------------------------- the public name

locals {
  proxy_site = var.public_hostname != "" && var.cloudflare_zone_id != ""
  # Cloudflare rules match on the request's host name.
  on_host = "(http.host eq \"${var.public_hostname}\")"
}

# Cloudflare's proxy answers on the public name and fetches the page from the storage endpoint. Storage only
# answers to its own host name, so the proxy sends that one (the origin rule), and it does not check the
# storage certificate against the public name (SSL mode Full, set for this host only).
resource "cloudflare_dns_record" "site" {
  count   = local.proxy_site ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.public_hostname
  type    = "CNAME"
  content = azurerm_storage_account.site.primary_web_host
  ttl     = 1
  proxied = true
  comment = "Contest Keeper website (${var.name}), made by Terraform"
}

# A zone has one ruleset per phase. This environment's Terraform owns the two below, so no other tool or
# environment may make rules in the same phases of this zone.
resource "cloudflare_ruleset" "site_origin" {
  count   = local.proxy_site ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = "Contest Keeper website origin"
  kind    = "zone"
  phase   = "http_request_origin"

  rules = [{
    action      = "route"
    description = "Send the storage host name to the website storage"
    enabled     = true
    expression  = local.on_host
    action_parameters = {
      host_header = azurerm_storage_account.site.primary_web_host
    }
  }]
}

resource "cloudflare_ruleset" "site_ssl" {
  count   = local.proxy_site ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = "Contest Keeper website SSL mode"
  kind    = "zone"
  phase   = "http_config_settings"

  rules = [{
    action      = "set_config"
    description = "Full: the storage certificate is not for the public name"
    enabled     = true
    expression  = local.on_host
    action_parameters = {
      ssl = "full"
    }
  }]
}
