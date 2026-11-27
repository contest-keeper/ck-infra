# Production: always on. Names and domains are not set here: the names default in variables.tf and the
# domains come from the GitHub environment variables HUB_DOMAIN and MAIL_DOMAIN (see deploy.yml).
min_replicas = 1
# Big enough for a 500-stick contest (ck-hub docs/capacity.md: about 0.3 core measured on a PC).
hub_cpu    = 0.5
hub_memory = "1Gi"
# The proxy in front of the Hub is always on (about 6 USD a month): one that has to wake can take longer than
# the 5 seconds a stick waits, and what the stick sent is then not queued.
ingress_min_replicas = 1
