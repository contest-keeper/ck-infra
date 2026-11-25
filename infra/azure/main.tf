data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result
  base   = "${var.name}-${local.suffix}"
}

# The generated password is kept in the Terraform state (private, Azure AD only). The Container App no
# longer holds it: it reads the database address from the Key Vault through its own identity (below).
resource "random_password" "db" {
  length  = 40
  special = false
}

# Made by bootstrap.sh, so the identity that deploys needs rights on this one group only.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# ---------------------------------------------------------------- database

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "psql-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  version             = "16"
  sku_name            = "B_Standard_B1ms"
  storage_mb          = 32768

  administrator_login               = "ckhub"
  administrator_password_wo         = random_password.db.result
  administrator_password_wo_version = var.db_password_version

  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true
  tags                          = var.tags

  lifecycle {
    # A plan that would delete or replace the database fails here instead of being applied.
    prevent_destroy = true
    # The zone Azure picks at creation must not make Terraform want to move the server.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "hub" {
  name      = "ckhub"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Plain connections are refused: the Hub connects over TLS (sslmode=require in its address).
resource "azurerm_postgresql_flexible_server_configuration" "require_tls" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "min_tls" {
  name      = "ssl_min_protocol_version"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "TLSv1.2"
}

# Only the Container App's own outbound addresses may reach the database (it is not on a virtual
# network: the shared environment it joins has none, and a Flexible Server can only be made private
# at creation). The app lists one to a few addresses; there are a fixed number of rules, and a spare
# one repeats the last address, so the rule names stay stable while the list is unknown at plan time.
# Every deploy refreshes them, so a changed address follows the next deploy.
locals {
  app_outbound_ips = azurerm_container_app.hub.outbound_ip_addresses
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "app" {
  count            = 4
  name             = "app-outbound-${count.index}"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = local.app_outbound_ips[min(count.index, length(local.app_outbound_ips) - 1)]
  end_ip_address   = local.app_outbound_ips[min(count.index, length(local.app_outbound_ips) - 1)]

  lifecycle {
    precondition {
      condition     = length(local.app_outbound_ips) >= 1 && length(local.app_outbound_ips) <= 4
      error_message = "The Container App lists ${length(local.app_outbound_ips)} outbound addresses; the database rules cover 1 to 4."
    }
  }
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "client" {
  count            = length(var.allowed_client_ips)
  name             = "client-${count.index}"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = var.allowed_client_ips[count.index]
  end_ip_address   = var.allowed_client_ips[count.index]
}

# ---------------------------------------------------------------- secrets

resource "azurerm_key_vault" "this" {
  name                       = "kv-${var.name}-${local.suffix}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = data.azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 30
  tags                       = var.tags

  # A plan that would delete or replace the vault fails here instead of being applied.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "deployer_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# New role assignments take a moment to apply.
resource "time_sleep" "rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.deployer_secrets]
}

resource "azurerm_key_vault_secret" "database_url" {
  name             = "database-url"
  key_vault_id     = azurerm_key_vault.this.id
  value_wo         = "postgres://ckhub:${random_password.db.result}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${azurerm_postgresql_flexible_server_database.hub.name}?sslmode=require"
  value_wo_version = var.db_password_version
  content_type     = "text/plain"
  tags             = var.tags

  depends_on = [time_sleep.rbac]
}

# ---------------------------------------------------------------- downloads

# Installers live in a private container. The Hub sends visitors to a link that works for a few
# minutes, signed with this account's key, so the storage address is never public.
resource "azurerm_storage_account" "downloads" {
  name                            = "${var.name}dl${local.suffix}"
  resource_group_name             = data.azurerm_resource_group.this.name
  location                        = data.azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  # No account key can sign or read anything: the Hub signs links with its identity, and the publish
  # workflow uploads with the deploy identity (its data role comes from bootstrap.sh). Apply this only
  # after publish-download.yml uses `--auth-mode login`, or the publish step fails.
  shared_access_key_enabled = false
  tags                      = merge(var.tags, { component = "downloads" })

  # A plan that would delete or replace the account (and the recordings in it) fails here.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "downloads" {
  name                  = "downloads"
  storage_account_id    = azurerm_storage_account.downloads.id
  container_access_type = "private"
}

# Recordings sticks upload (screen video and snapshots) go to their own private container in the same
# account. Only the Hub reads and writes it, with short-lived links signed by the account key. The
# Hub deletes a recording when its retention has passed.
resource "azurerm_storage_container" "recordings" {
  name                  = "recordings"
  storage_account_id    = azurerm_storage_account.downloads.id
  container_access_type = "private"
}

# ---------------------------------------------------------------- the Hub's identity

# The Hub signs in to Azure as this identity: no key or password in the app. It is made before the app
# because the app's secret refers to it. The roles are the least it needs.
resource "azurerm_user_assigned_identity" "hub" {
  name                = "id-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = var.tags
}

# Reads the database address from the Key Vault (secrets only, no keys or certificates).
resource "azurerm_role_assignment" "hub_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.hub.principal_id
}

# Asks storage for a user delegation key, which signs the short-lived download and upload links
# (replaces the account key). It lets the holder sign links but not read or write any blob by itself.
resource "azurerm_role_assignment" "hub_delegator" {
  scope                = azurerm_storage_account.downloads.id
  role_definition_name = "Storage Blob Delegator"
  principal_id         = azurerm_user_assigned_identity.hub.principal_id
}

# What a link may then reach: installers are only read, recordings are written, read and deleted.
resource "azurerm_role_assignment" "hub_downloads" {
  scope                = azurerm_storage_container.downloads.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.hub.principal_id
}

resource "azurerm_role_assignment" "hub_recordings" {
  scope                = azurerm_storage_container.recordings.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.hub.principal_id
}

# New role assignments take a moment to apply, and the app reads the secret as it starts.
resource "time_sleep" "hub_roles" {
  create_duration = "60s"
  depends_on = [
    azurerm_role_assignment.hub_secrets,
    azurerm_role_assignment.hub_delegator,
    azurerm_role_assignment.hub_downloads,
    azurerm_role_assignment.hub_recordings,
  ]
}

# ---------------------------------------------------------------- the Hub

# Where the Hub runs. By default it gets an environment of its own. When shared_environment_name is set it joins
# an existing one instead (a subscription may allow only one regular environment, and only a regular one can
# have a custom domain). The shared one is only read here: its owner keeps it.
locals {
  own_environment = var.shared_environment_name == ""
}

data "azurerm_container_app_environment" "shared" {
  count               = local.own_environment ? 0 : 1
  name                = var.shared_environment_name
  resource_group_name = var.shared_environment_resource_group
}

moved {
  from = azurerm_log_analytics_workspace.this
  to   = azurerm_log_analytics_workspace.this[0]
}

moved {
  from = azurerm_container_app_environment.this
  to   = azurerm_container_app_environment.this[0]
}

resource "azurerm_log_analytics_workspace" "this" {
  count               = local.own_environment ? 1 : 0
  name                = "log-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_container_app_environment" "this" {
  count                      = local.own_environment ? 1 : 0
  name                       = "cae-${local.base}"
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = data.azurerm_resource_group.this.location
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this[0].id
  tags                       = var.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app" "hub" {
  name                         = "ca-${local.base}"
  resource_group_name          = data.azurerm_resource_group.this.name
  container_app_environment_id = local.own_environment ? azurerm_container_app_environment.this[0].id : data.azurerm_container_app_environment.shared[0].id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.hub.id]
  }

  # The address (with the password) stays in the Key Vault; the app reads it with its identity.
  secret {
    name                = "database-url"
    key_vault_secret_id = azurerm_key_vault_secret.database_url.versionless_id
    identity            = azurerm_user_assigned_identity.hub.id
  }

  # The key the Hub signs stick settings with. Without it the Hub answers 503 to a signing request.
  dynamic "secret" {
    for_each = var.config_signing_key != "" ? [1] : []

    content {
      name  = "config-signing-key"
      value = var.config_signing_key
    }
  }

  dynamic "secret" {
    for_each = local.mail ? [1] : []

    content {
      name  = "mail-key"
      value = azurerm_communication_service.mail[0].primary_key
    }
  }

  # The image is private, so Azure signs in to ghcr.io with a token that can only read packages.
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

  # The sender must be verified and linked before the Hub starts sending from it.
  depends_on = [
    azurerm_communication_service_email_domain_association.mail,
    time_sleep.hub_roles,
  ]

  # One copy only: login lockouts are counted in the Hub's memory.
  template {
    min_replicas = var.min_replicas
    max_replicas = 1

    container {
      name   = "hub"
      image  = var.image
      cpu    = var.hub_cpu
      memory = var.hub_memory

      env {
        name        = "CK_DATABASE_URL"
        secret_name = "database-url"
      }

      # Names the identity that signs storage links.
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.hub.client_id
      }

      env {
        name  = "CK_DOWNLOAD_ACCOUNT"
        value = azurerm_storage_account.downloads.name
      }

      env {
        name  = "CK_DOWNLOAD_CONTAINER"
        value = azurerm_storage_container.downloads.name
      }

      env {
        name  = "CK_RECORDINGS_CONTAINER"
        value = azurerm_storage_container.recordings.name
      }

      dynamic "env" {
        for_each = var.config_signing_key != "" ? [1] : []

        content {
          name        = "CK_CONFIG_SIGNING_KEY"
          secret_name = "config-signing-key"
        }
      }

      dynamic "env" {
        for_each = local.mail_env

        content {
          name        = env.value.name
          value       = env.value.value
          secret_name = env.value.secret_name
        }
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/"
        port      = 8088
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/"
        port      = 8088
      }
    }
  }

}

# ---------------------------------------------------------------- custom domain

locals {
  # Both the hostname and the zone it lives in are needed for Terraform to make the DNS records.
  manage_dns = var.custom_domain != "" && var.cloudflare_zone_id != ""
}

# The records Azure looks for before it adds the name. Both stay "DNS only": a proxied record hides them
# from Azure's check.
resource "cloudflare_dns_record" "hub_cname" {
  count   = local.manage_dns ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.custom_domain
  type    = "CNAME"
  content = azurerm_container_app.hub.ingress[0].fqdn
  ttl     = 1
  proxied = false
  comment = "Keeper Hub (${var.name}), made by Terraform"
}

resource "cloudflare_dns_record" "hub_verification" {
  count   = local.manage_dns ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = "asuid.${var.custom_domain}"
  type    = "TXT"
  content = azurerm_container_app.hub.custom_domain_verification_id
  ttl     = 1
  comment = "Azure domain check for Keeper Hub (${var.name}), made by Terraform"
}

# A new record takes a moment to reach the resolvers Azure asks.
resource "time_sleep" "dns" {
  count           = local.manage_dns ? 1 : 0
  create_duration = "60s"
  depends_on      = [cloudflare_dns_record.hub_cname, cloudflare_dns_record.hub_verification]
}

# Azure checks the DNS records before it adds the name, and then issues and renews a free certificate for
# it. Without a certificate id Azure makes the managed one itself; it sets the two fields below
# afterwards, so Terraform must not try to change them back.
resource "azurerm_container_app_custom_domain" "hub" {
  count            = var.custom_domain != "" ? 1 : 0
  name             = var.custom_domain
  container_app_id = azurerm_container_app.hub.id

  depends_on = [time_sleep.dns]

  lifecycle {
    ignore_changes = [certificate_binding_type, container_app_environment_certificate_id]
  }
}

# Adding the name does not make its certificate: the hostname stays unbound ("Disabled") and HTTPS fails.
# Azure makes the free managed certificate and attaches it with this command. It waits until the certificate
# is issued, which can take a while. It runs again only when the hostname or the app is made again, never on
# an ordinary deploy, and it is safe to repeat. The deploy has signed in with az already.
resource "terraform_data" "hub_certificate" {
  count            = var.custom_domain != "" ? 1 : 0
  triggers_replace = [azurerm_container_app_custom_domain.hub[0].id, azurerm_container_app.hub.id]

  provisioner "local-exec" {
    command = join(" ", [
      "az containerapp hostname bind",
      "--resource-group ${data.azurerm_resource_group.this.name}",
      "--name ${azurerm_container_app.hub.name}",
      "--hostname ${var.custom_domain}",
      "--environment ${local.own_environment ? azurerm_container_app_environment.this[0].id : data.azurerm_container_app_environment.shared[0].id}",
      "--validation-method CNAME",
    ])
  }
}
