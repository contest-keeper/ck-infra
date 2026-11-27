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

# Made by bootstrap.sh, so the identity that deploys needs rights on this one group only.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# ---------------------------------------------------------------- database

# Postgres at Neon (the free plan): it sleeps when idle, so an environment that is not used costs nothing. TLS is
# required by Neon. The password is made by Neon and kept in the private Terraform state (Azure AD only); the
# Container App reads the database address from the Key Vault through its own identity (below). The Hub reopens a
# connection that Neon closed while asleep, and its only background queries are the hourly clean-ups.
resource "neon_project" "this" {
  name       = local.base
  org_id     = var.neon_org_id != "" ? var.neon_org_id : null
  region_id  = var.neon_region
  pg_version = 16

  history_retention_seconds = var.neon_history_retention_seconds

  branch {
    name          = "main"
    database_name = "ckhub"
    role_name     = "ckhub"
  }

  lifecycle {
    # A plan that would delete or replace the database fails here instead of being applied.
    prevent_destroy = true
  }
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
  name         = "database-url"
  key_vault_id = azurerm_key_vault.this.id
  value        = "postgres://${neon_project.this.database_user}:${neon_project.this.database_password}@${neon_project.this.database_host}/${neon_project.this.database_name}?sslmode=require"
  content_type = "text/plain"
  tags         = var.tags

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
    azurerm_role_assignment.hub_queue,
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

# Send Key Vault audit events to the Hub's Log Analytics workspace so secret reads and key operations are logged.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  count                      = local.own_environment ? 1 : 0
  name                       = "kv-audit-logs"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this[0].id

  enabled_log {
    category = "AuditEvent"
  }
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

  # What the proxy in front of the Hub proves itself with.
  dynamic "secret" {
    for_each = var.outage_queue ? [1] : []

    content {
      name  = "ingress-secret"
      value = random_password.ingress[0].result
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

      # A new database makes a new revision, which reads the new address from the Key Vault at once.
      env {
        name  = "CK_DATABASE_ID"
        value = neon_project.this.id
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

      # What waited while the Hub could not be reached.
      dynamic "env" {
        for_each = var.outage_queue ? [1] : []

        content {
          name  = "CK_QUEUE_URL"
          value = local.queue_url
        }
      }

      dynamic "env" {
        for_each = var.outage_queue ? [1] : []

        content {
          name        = "CK_INGRESS_SECRET"
          secret_name = "ingress-secret"
        }
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

  # The app the custom domain leads to: the proxy once the cut over is made, the Hub until then.
  front = var.ingress_serves_domain ? azurerm_container_app.ingress[0] : azurerm_container_app.hub
}

# The records Azure looks for before it adds the name. Both stay "DNS only": a proxied record hides them
# from Azure's check.
resource "cloudflare_dns_record" "hub_cname" {
  count   = local.manage_dns ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.custom_domain
  type    = "CNAME"
  content = local.front.ingress[0].fqdn
  ttl     = 1
  proxied = false
  comment = "Keeper Hub (${var.name}), made by Terraform"
}

resource "cloudflare_dns_record" "hub_verification" {
  count   = local.manage_dns ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = "asuid.${var.custom_domain}"
  type    = "TXT"
  content = local.front.custom_domain_verification_id
  ttl     = 1
  comment = "Azure domain check for Keeper Hub (${var.name}), made by Terraform"
}

# A new record takes a moment to reach the resolvers Azure asks.
resource "time_sleep" "dns" {
  count           = local.manage_dns ? 1 : 0
  create_duration = "60s"
  # Waits again when the records change to another app.
  triggers   = { target = local.front.ingress[0].fqdn }
  depends_on = [cloudflare_dns_record.hub_cname, cloudflare_dns_record.hub_verification]
}

# Azure checks the DNS records before it adds the name, and then issues and renews a free certificate for
# it. Without a certificate id Azure makes the managed one itself; it sets the two fields below
# afterwards, so Terraform must not try to change them back.
resource "azurerm_container_app_custom_domain" "hub" {
  count            = var.custom_domain != "" ? 1 : 0
  name             = var.custom_domain
  container_app_id = local.front.id

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
  triggers_replace = [azurerm_container_app_custom_domain.hub[0].id, local.front.id]

  provisioner "local-exec" {
    command = join(" ", [
      "az containerapp hostname bind",
      "--resource-group ${data.azurerm_resource_group.this.name}",
      "--name ${local.front.name}",
      "--hostname ${var.custom_domain}",
      "--environment ${local.own_environment ? azurerm_container_app_environment.this[0].id : data.azurerm_container_app_environment.shared[0].id}",
      "--validation-method CNAME",
    ])
  }
}

# ---------------------------------------------------------------- image publisher

# The identity the Keeper OS image workflow (ck-os) signs in as to upload an image to the downloads container.
# Only when image_publisher_subject is set (develop); production gets its images through a release instead.
resource "azurerm_user_assigned_identity" "image_publisher" {
  count               = var.image_publisher_subject != "" ? 1 : 0
  name                = "id-${local.base}-image-publish"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "image_publisher" {
  count                     = var.image_publisher_subject != "" ? 1 : 0
  name                      = "github-image-publish"
  user_assigned_identity_id = azurerm_user_assigned_identity.image_publisher[0].id
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = var.image_publisher_subject
  audience                  = ["api://AzureADTokenExchange"]
}

# The container only, not the account: the publisher cannot reach the recordings.
resource "azurerm_role_assignment" "image_publisher" {
  count                = var.image_publisher_subject != "" ? 1 : 0
  scope                = azurerm_storage_container.downloads.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.image_publisher[0].principal_id
}
