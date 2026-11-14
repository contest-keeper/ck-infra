output "storage_account" {
  description = "The storage account that serves the site."
  value       = azurerm_storage_account.site.name
}

output "website_url" {
  description = "The address of the site."
  value       = azurerm_storage_account.site.primary_web_endpoint
}

output "public_url" {
  description = "The public address of the site, or the storage address without a public name."
  value       = local.proxy_site ? "https://${var.public_hostname}/" : azurerm_storage_account.site.primary_web_endpoint
}
