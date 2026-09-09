variable "aws_profile" {
  description = "AWS CLI/SSO profile to deploy with. This is the personal account (414700437904), NOT any CreditGenie account."
  type        = string
  default     = "aidb-personal"
}

variable "aws_region" {
  description = "Region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name/tag prefix for all resources. Also the tag the DLM backup policy and self-stop logic key on."
  type        = string
  default     = "palworld-server"
}

variable "instance_type" {
  description = "EC2 instance type. t3.xlarge = 4 vCPU / 16 GB, matches Pocketpair's recommended spec for a 5-10 player server."
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_gb" {
  description = "Root EBS volume size (GB). Holds the OS, server binary, world save, and local backups."
  type        = number
  default     = 50
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH (port 22) for admin uploads. Set to your own IP, e.g. 'x.x.x.x/32' (get it with: curl -s ifconfig.me). Do NOT use 0.0.0.0/0."
  type        = string
}

variable "server_name" {
  description = "Display name of the server as it appears to players."
  type        = string
  default     = "Palworld"
}

variable "server_password" {
  description = "Password players must enter to join. Empty string = open server (still IP-gated by direct-connect)."
  type        = string
  sensitive   = true
}

variable "idle_shutdown_minutes" {
  description = "Minutes of zero connected players before the server self-shuts-down (OS shutdown -> AWS stops the instance, halting compute billing)."
  type        = number
  default     = 30
}

variable "discord_webhook_url" {
  description = "Optional Discord incoming-webhook URL. If set, the server posts a one-line notice here before it idle-shuts-down. Leave empty to disable."
  type        = string
  default     = ""
  sensitive   = true
}

# --- Discord start-bot ---
# Neither of these is a secret: Discord publishes the app id and the Ed25519
# public key. They are inputs, not credentials, so they are not marked sensitive.
variable "discord_public_key" {
  description = "Discord application's Ed25519 public key (64 hex chars). Used to verify interaction signatures."
  type        = string
  default     = ""

  validation {
    condition     = var.discord_public_key == "" || can(regex("^[0-9a-fA-F]{64}$", var.discord_public_key))
    error_message = "discord_public_key must be exactly 64 hexadecimal characters (32 bytes)."
  }
}

variable "discord_app_id" {
  description = "Discord application (client) ID — the snowflake used to edit deferred interaction responses."
  type        = string
  default     = ""
}

variable "discord_allowed_user_ids" {
  description = "Discord user-ID snowflakes permitted to run /pow-start. Anyone else is refused."
  type        = list(string)
  default     = []
}

variable "billing_alarm_usd" {
  description = "Alarm when estimated AWS charges exceed this many USD. 0 disables the alarm."
  type        = number
  default     = 30
}

variable "idle_warn_before_minutes" {
  description = "Post a Discord warning this many minutes before the idle shutdown fires."
  type        = number
  default     = 5

  validation {
    condition     = var.idle_warn_before_minutes < var.idle_shutdown_minutes
    error_message = "idle_warn_before_minutes must be less than idle_shutdown_minutes, or the warning can never fire."
  }
}

variable "alert_email" {
  description = "Address to notify when the backup monitor itself fails. Deliberately a channel independent of Discord, because a broken Discord webhook is one of the failures this must surface. Empty = topic created but nothing subscribed. AWS sends a confirmation mail that must be clicked before delivery starts."
  type        = string
  default     = ""
}

variable "world_volume_gb" {
  description = "Dedicated EBS volume for the Linux world save. Separate from the root volume so an instance replacement cannot delete the world (see AIDB postmortem 2026-07-18). The world is ~80 MB; the size is for headroom and local backups, not need."
  type        = number
  default     = 20
}

# --- Presence daemon (always-on t4g.nano) ---
variable "enable_presence_bot" {
  description = "Run the always-on t4g.nano that holds Discord's Gateway socket (~$7.36/mo). false = no instance."
  type        = bool
  default     = false
}

variable "discord_bot_token" {
  description = "Discord bot token. A full takeover of the bot identity — treat as a credential. Seeded into SSM; rotate there, not here."
  type        = string
  default     = ""
  sensitive   = true
}
