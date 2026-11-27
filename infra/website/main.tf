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
  # No account key can sign or read anything: deploys upload with the deploy identity (--auth-mode login)
  # and Terraform reads/configures the static website over Entra ID (storage_use_azuread = true).
  shared_access_key_enabled = false
  tags                      = var.tags
}

resource "azurerm_storage_account_static_website" "site" {
  storage_account_id = azurerm_storage_account.site.id
  index_document     = "index.html"
  error_404_document = "index.html"
}

# ---------------------------------------------------------------- the public name

locals {
  proxy_site = var.public_hostname != "" && var.cloudflare_zone_id != "" && var.cloudflare_account_id != ""
}

# Cloudflare's proxy answers on the public name, and a small Worker fetches the page from the storage endpoint.
# Storage only answers to its own host name, and rewriting the Host header with a rule is not allowed on every
# Cloudflare plan, so the Worker makes the request itself. It checks the storage certificate like any browser.
# The record must be proxied for the Worker to run; where it points does not matter.
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

resource "cloudflare_workers_script" "site" {
  count       = local.proxy_site ? 1 : 0
  account_id  = var.cloudflare_account_id
  script_name = "ck-website-${var.name}"
  main_module = "worker.js"
  content     = <<-EOT
    // Serves the website from its storage endpoint under the public name. Made by Terraform.
    export default {
      async fetch(request) {
        const url = new URL(request.url);
        url.protocol = "https:";
        url.hostname = "${azurerm_storage_account.site.primary_web_host}";
        url.port = "";
        return fetch(new Request(url, request));
      },
    };
  EOT
}

resource "cloudflare_workers_route" "site" {
  count   = local.proxy_site ? 1 : 0
  zone_id = var.cloudflare_zone_id
  pattern = "${var.public_hostname}/*"
  script  = cloudflare_workers_script.site[0].script_name
}
