# The proxy in front of the Hub: the Hub's own image, run as `ck-hub ingress`. It passes every request on,
# queues what sticks send while the Hub cannot take it, and serves /status, which stays up when the Hub does
# not. The custom domain moves to it when ingress_serves_domain is true.

# The Hub believes the client address the proxy sends only together with this secret. Like the database
# password it is kept in the Terraform state (private, Azure AD only).
resource "random_password" "ingress" {
  count = var.outage_queue ? 1 : 0

  length  = 48
  special = false
}

resource "azurerm_user_assigned_identity" "ingress" {
  count = var.outage_queue ? 1 : 0

  name                = "id-${local.base}-ingress"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = var.tags
}

# The status history, so it survives a restart. Its own container: the proxy reaches no installer or recording.
resource "azurerm_storage_container" "status" {
  count = var.outage_queue ? 1 : 0

  name                  = "status"
  storage_account_id    = azurerm_storage_account.downloads.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "ingress_queue" {
  count = var.outage_queue ? 1 : 0

  scope                = azurerm_servicebus_queue.reports[0].id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_user_assigned_identity.ingress[0].principal_id
}

resource "azurerm_role_assignment" "ingress_status" {
  count = var.outage_queue ? 1 : 0

  scope                = azurerm_storage_container.status[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ingress[0].principal_id
}

# New role assignments take a moment to apply.
resource "time_sleep" "ingress_roles" {
  count = var.outage_queue ? 1 : 0

  create_duration = "60s"
  depends_on = [
    azurerm_role_assignment.ingress_queue,
    azurerm_role_assignment.ingress_status,
  ]
}

resource "azurerm_container_app" "ingress" {
  count = var.outage_queue ? 1 : 0

  name                         = "ca-${local.base}-in"
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = local.own_environment ? azurerm_container_app_environment.this[0].id : data.azurerm_container_app_environment.shared[0].id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ingress[0].id]
  }

  secret {
    name  = "ingress-secret"
    value = random_password.ingress[0].result
  }

  dynamic "secret" {
    for_each = var.registry_password != "" ? [1] : []

    content {
      name  = "registry-password"
      value = var.registry_password
    }
  }

  dynamic "registry" {
    for_each = var.registry_password != "" ? [1] : []

    content {
      server               = "ghcr.io"
      username             = "contest-keeper"
      password_secret_name = "registry-password"
    }
  }

  ingress {
    external_enabled           = true
    target_port                = 8088
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [time_sleep.ingress_roles]

  # One copy only: the status history and the per-address limit are kept in its memory.
  template {
    min_replicas = var.ingress_min_replicas
    max_replicas = 1

    container {
      name   = "ingress"
      image  = var.image
      args   = ["ingress"]
      cpu    = var.ingress_cpu
      memory = var.ingress_memory

      env {
        name  = "CK_HUB_URL"
        value = "https://${azurerm_container_app.hub.ingress[0].fqdn}"
      }

      env {
        name  = "CK_QUEUE_URL"
        value = local.queue_url
      }

      env {
        name        = "CK_INGRESS_SECRET"
        secret_name = "ingress-secret"
      }

      env {
        name  = "CK_STATUS_URL"
        value = "${azurerm_storage_account.downloads.primary_blob_endpoint}${azurerm_storage_container.status[0].name}/history.json"
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.ingress[0].client_id
      }

      # Only that it listens: a page would be asked of the Hub, and the proxy must stay up without it.
      liveness_probe {
        transport = "TCP"
        port      = 8088
      }

      readiness_probe {
        transport = "TCP"
        port      = 8088
      }
    }
  }
}
