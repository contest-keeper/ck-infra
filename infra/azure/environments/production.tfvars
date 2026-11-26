# Production: always on. Names and domains are not set here: the names default in variables.tf and the
# domains come from the GitHub environment variables HUB_DOMAIN and MAIL_DOMAIN (see deploy.yml).
min_replicas = 1
# Big enough for a 500-stick contest (ck-hub docs/capacity.md: about 0.3 core measured on a PC).
hub_cpu    = 0.5
hub_memory = "1Gi"
