variable "name" {
  description = "Short name used in resource names. Lowercase letters and digits, at most 14."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,14}$", var.name))
    error_message = "Use 3 to 14 lowercase letters or digits."
  }
}

variable "resource_group_name" {
  description = "The resource group bootstrap.sh made for this environment. Everything is created inside it, in its region."
  type        = string
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = { project = "contest-keeper", component = "website" }
}

variable "public_hostname" {
  description = "The name the site answers on, for example dev.contestkeeper.com. It is served through a Cloudflare Worker, which gives it HTTPS: a storage static website cannot do HTTPS on its own name. Needs cloudflare_zone_id and cloudflare_account_id. Leave empty to use only the storage address."
  type        = string
  default     = ""

  validation {
    condition     = var.public_hostname == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}$", var.public_hostname))
    error_message = "Use a lowercase hostname such as dev.contestkeeper.com."
  }
}

variable "cloudflare_zone_id" {
  description = "The Cloudflare zone that holds public_hostname. Not a secret. Leave empty to make no DNS record."
  type        = string
  default     = ""

  validation {
    condition     = var.cloudflare_zone_id == "" || can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "A Cloudflare zone id is 32 lowercase hex characters (domain Overview page, API section)."
  }
}

variable "cloudflare_account_id" {
  description = "The Cloudflare account that owns the Worker. Not a secret. Leave empty to make no Worker."
  type        = string
  default     = ""

  validation {
    condition     = var.cloudflare_account_id == "" || can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "A Cloudflare account id is 32 lowercase hex characters."
  }
}
