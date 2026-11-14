# Mail for the Hub through Azure Communication Services Email. The Hub signs its requests with this service's
# access key and sends from noreply@<mail_domain>. A sender domain must be verified before Azure sends from it,
# so the records Azure asks for are made in Cloudflare, and the verification is started with az rest (Terraform
# cannot start it). Needs the resource provider Microsoft.Communication registered once in the subscription.

locals {
  # The Hub's links point at its public name, and the records live in the Cloudflare zone.
  mail = var.mail_domain != "" && var.cloudflare_zone_id != "" && var.custom_domain != ""

  mail_record_kinds = toset(["domain", "spf", "dkim", "dkim2"])
}

resource "azurerm_email_communication_service" "mail" {
  count               = local.mail ? 1 : 0
  name                = "ecs-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  data_location       = "Europe"
  tags                = var.tags
}

resource "azurerm_email_communication_service_domain" "mail" {
  count             = local.mail ? 1 : 0
  name              = var.mail_domain
  email_service_id  = azurerm_email_communication_service.mail[0].id
  domain_management = "CustomerManaged"
}

resource "azurerm_email_communication_service_domain_sender_username" "noreply" {
  count                   = local.mail ? 1 : 0
  name                    = "noreply"
  email_service_domain_id = azurerm_email_communication_service_domain.mail[0].id
}

resource "azurerm_communication_service" "mail" {
  count               = local.mail ? 1 : 0
  name                = "cs-${local.base}"
  resource_group_name = data.azurerm_resource_group.this.name
  data_location       = "Europe"
  tags                = var.tags
}

# The four records Azure asks for: ownership (TXT), SPF (TXT) and two DKIM keys (CNAME). Azure gives the TXT
# names as the full domain and the DKIM names relative to it, and may give "@" for the domain itself, so a name
# that already is (or ends with) the domain is used as it is.
locals {
  mail_record = {
    for kind in local.mail_record_kinds : kind => local.mail ? azurerm_email_communication_service_domain.mail[0].verification_records[0][kind][0] : null
  }
  mail_record_name = {
    for kind, record in local.mail_record : kind => (
      record.name == "@" || endswith(record.name, var.mail_domain) ? (record.name == "@" ? var.mail_domain : record.name) : "${record.name}.${var.mail_domain}"
    ) if record != null
  }
}

resource "cloudflare_dns_record" "mail" {
  for_each = local.mail ? local.mail_record_kinds : toset([])
  zone_id  = var.cloudflare_zone_id
  name     = local.mail_record_name[each.key]
  type     = local.mail_record[each.key].type
  content  = local.mail_record[each.key].value
  ttl      = 1
  proxied  = false
  comment  = "Keeper Hub mail (${var.name}), made by Terraform"
}

# A new record takes a moment to reach the resolvers Azure asks.
resource "time_sleep" "mail_dns" {
  count           = local.mail ? 1 : 0
  create_duration = "60s"
  depends_on      = [cloudflare_dns_record.mail]
}

# Starts the four checks and waits (at most ten minutes) until Azure reports every one as Verified. Runs again
# only when the domain is made again, and is safe to repeat. The deploy has signed in with az already.
resource "terraform_data" "mail_verification" {
  count            = local.mail ? 1 : 0
  triggers_replace = [azurerm_email_communication_service_domain.mail[0].id]

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      base="https://management.azure.com${azurerm_email_communication_service_domain.mail[0].id}"
      api="api-version=2023-04-01"
      for kind in Domain SPF DKIM DKIM2; do
        az rest --method post --url "$base/initiateVerification?$api" --body "{\"verificationType\":\"$kind\"}" --output none
      done
      for attempt in $(seq 1 40); do
        states=$(az rest --method get --url "$base?$api" --query "[properties.verificationStates.Domain.status, properties.verificationStates.SPF.status, properties.verificationStates.DKIM.status, properties.verificationStates.DKIM2.status]" -o tsv | tr '\n' ' ')
        echo "attempt $attempt: $states"
        if [ "$states" = "Verified Verified Verified Verified " ]; then exit 0; fi
        sleep 15
      done
      echo "the mail domain was not verified in time" >&2
      exit 1
    EOT
  }

  depends_on = [time_sleep.mail_dns]
}

resource "azurerm_communication_service_email_domain_association" "mail" {
  count                    = local.mail ? 1 : 0
  communication_service_id = azurerm_communication_service.mail[0].id
  email_service_domain_id  = azurerm_email_communication_service_domain.mail[0].id

  depends_on = [terraform_data.mail_verification]
}

locals {
  # What the Hub needs to send mail. The key is a Container App secret, never a plain value.
  mail_env = local.mail ? [
    { name = "CK_MAIL", value = "acs", secret_name = null },
    { name = "CK_PUBLIC_URL", value = "https://${var.custom_domain}", secret_name = null },
    { name = "CK_MAIL_ENDPOINT", value = "https://${azurerm_communication_service.mail[0].hostname}", secret_name = null },
    { name = "CK_MAIL_FROM", value = "noreply@${var.mail_domain}", secret_name = null },
    { name = "CK_ACS_KEY", value = null, secret_name = "mail-key" },
  ] : []
}
