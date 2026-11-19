# Develop: its own small copy, asleep when nobody uses it.
name                = "ckhubdev"
resource_group_name = "rg-ckhub-dev"
min_replicas        = 0
# The subscription allows one regular Container Apps environment, which kc-dash already has. Only a regular
# one can have a custom domain, so the Hub joins it (docs/azure.md: the join permission comes first).
shared_environment_name           = "kc-dash-env"
shared_environment_resource_group = "rg-kc-dash"
custom_domain                     = "hub.dev.contestkeeper.com"
mail_domain                       = "mail.dev.contestkeeper.com"
# The smallest size the Hub runs in. It sleeps when idle, so it costs little; a load test of the
# develop Hub is the only reason to raise it.
hub_cpu    = 0.25
hub_memory = "0.5Gi"
