# What sticks send while the Hub cannot take it waits here: the proxy in front of the Hub (ingress.tf) puts
# it in, and the Hub takes it out when it can again. Needs the resource provider Microsoft.ServiceBus
# registered once in the subscription (bootstrap.sh).
#
# Basic has no monthly fee: only the operations are billed.
#
# All of it, and the proxy, is made only when outage_queue is on.

resource "azurerm_servicebus_namespace" "this" {
  count = var.outage_queue ? 1 : 0

  name                = "sb-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  sku                 = "Basic"
  # Basic has no network rules or private endpoints, so the endpoint is public. What guards it:
  public_network_access_enabled = true
  # No shared access keys: only the two identities below can send or receive.
  local_auth_enabled  = false
  minimum_tls_version = "1.2"
  tags                = var.tags

  # A plan that would delete or replace the namespace (and the messages waiting in it) fails here.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_servicebus_queue" "reports" {
  count = var.outage_queue ? 1 : 0

  name         = "reports"
  namespace_id = azurerm_servicebus_namespace.this[0].id

  # The longest the tier allows: a whole contest of a large site fits, and waits out a long outage.
  max_size_in_megabytes = 5120
  default_message_ttl   = "P14D"
  # The Hub holds a message and renews its lock while it cannot keep it, so neither limit should ever be
  # reached. Both are generous because a message past them is set aside and nothing reads it again.
  lock_duration      = "PT5M"
  max_delivery_count = 2000
}

# The Hub takes messages out and nothing else.
resource "azurerm_role_assignment" "hub_queue" {
  count = var.outage_queue ? 1 : 0

  scope                = azurerm_servicebus_queue.reports[0].id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_user_assigned_identity.hub.principal_id
}

locals {
  queue_url = var.outage_queue ? "https://${azurerm_servicebus_namespace.this[0].name}.servicebus.windows.net/${azurerm_servicebus_queue.reports[0].name}" : ""
}
