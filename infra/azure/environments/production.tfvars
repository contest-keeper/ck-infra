# Production: always on.
name                = "ckhub"
resource_group_name = "rg-ckhub"
min_replicas        = 1
# Big enough for a 500-stick contest (ck-hub docs/capacity.md: about 0.3 core measured on a PC).
hub_cpu    = 0.5
hub_memory = "1Gi"
