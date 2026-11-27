# Develop: its own small copy, asleep when nobody uses it. Names and domains are not set here: the names
# default in variables.tf and the domains come from the GitHub environment variables HUB_DOMAIN and
# MAIL_DOMAIN (see deploy.yml).
min_replicas = 0
# The smallest size the Hub runs in. It sleeps when idle, so it costs little; a load test of the
# develop Hub is the only reason to raise it.
hub_cpu    = 0.25
hub_memory = "0.5Gi"
# The proxy in front of the Hub sleeps when idle. 1 keeps it always on, for about 6 USD a month.
ingress_min_replicas = 0
