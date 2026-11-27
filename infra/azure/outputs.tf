output "hub_url" {
  description = "Where organizers and sticks reach the Hub. HTTPS, with Azure's own certificate."
  value       = "https://${azurerm_container_app.hub.ingress[0].fqdn}"
}

output "ingress_url" {
  description = "The proxy in front of the Hub, on Azure's own address. Its status page is at /status."
  value       = "https://${azurerm_container_app.ingress.ingress[0].fqdn}"
}

output "queue_url" {
  description = "The Service Bus queue that holds what waited while the Hub could not take it."
  value       = local.queue_url
}

output "resource_group" {
  value = data.azurerm_resource_group.this.name
}

output "container_app" {
  value = azurerm_container_app.hub.name
}

output "key_vault" {
  value = azurerm_key_vault.this.name
}

output "database_host" {
  value = neon_project.this.database_host
}

output "download_storage_account" {
  description = "The private storage account that holds the installers."
  value       = azurerm_storage_account.downloads.name
}

output "custom_domain_verification_id" {
  description = "The value of the TXT record asuid.<hostname> that proves to Azure you own the custom domain. It goes into a public DNS record, so it is not a secret."
  value       = nonsensitive(local.front.custom_domain_verification_id)
}

output "custom_domain_target" {
  description = "What the CNAME record of the custom domain points to."
  value       = local.front.ingress[0].fqdn
}

output "mail_domain_id" {
  description = "The resource id of the mail sender domain, for checking its verification by hand. Empty without mail."
  value       = local.mail ? azurerm_email_communication_service_domain.mail[0].id : ""
}

output "hub_identity_client_id" {
  description = "The client id of the Hub's managed identity, for the Hub's storage sign-in."
  value       = azurerm_user_assigned_identity.hub.client_id
}

output "image_publisher_client_id" {
  description = "Client id of the image publisher identity: the ck-os variable CK_IMAGE_PUBLISH_CLIENT_ID. Empty when image_publisher_subject is not set."
  value       = one(azurerm_user_assigned_identity.image_publisher[*].client_id)
}
