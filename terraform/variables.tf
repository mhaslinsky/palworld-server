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
  description = "CIDR allowed to SSH (port 22) for admin + mod (UE4SS/.pak) uploads. Set to your own IP, e.g. 'x.x.x.x/32' (get it with: curl -s ifconfig.me). Do NOT use 0.0.0.0/0."
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

variable "admin_password" {
  description = "Server admin password. Also the credential for the RCON console AND the REST API that the idle-shutdown script polls."
  type        = string
  sensitive   = true
}

variable "rcon_port" {
  description = "RCON port (TCP). Kept OFF the public security group — localhost/admin use only."
  type        = number
  default     = 25575
}

variable "rest_api_port" {
  description = "Palworld REST API port (TCP). Kept OFF the public security group — the idle-shutdown script polls it on 127.0.0.1 only."
  type        = number
  default     = 8212
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

# --- Windows migration (parallel build; see 2026-07-11-windows-migration-plan) ---
# All Windows resources are gated on this flag so the default plan is a no-op and the
# live Linux instance is never in Terraform's create/replace path. Flip to true in
# terraform.tfvars only when standing up the parallel Windows box.
variable "enable_windows_migration" {
  description = "Create the parallel Windows Server 2022 game instance + its own save volume/SG. false = Linux-only, no Windows resources."
  type        = bool
  default     = false
}

variable "windows_root_volume_gb" {
  description = "Windows game instance root EBS (GB). Bigger than Linux: OS + pagefile + game + UE4SS overhead."
  type        = number
  default     = 100
}

variable "windows_save_volume_gb" {
  description = "Dedicated persistent EBS volume for SaveGames on the Windows box (survives instance replacement; prevent_destroy)."
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

# --- /ask Palworld Q&A bot ---
variable "parallel_api_key" {
  description = "Parallel AI Search API key for the /ask web-search tool. Seeded into SSM SecureString; rotate there, not here. Empty leaves a placeholder and disables search (the model answers from its own knowledge)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "parallel_search_url" {
  description = "Parallel AI Search API endpoint. Confirmed against live Parallel docs + SDK source (see the change's tasks.md 1.2)."
  type        = string
  default     = "https://api.parallel.ai/v1/search"
}

variable "bedrock_model_id" {
  description = "Bedrock model id the ask-worker invokes. Claude Haiku 4.5 is reached via a cross-region inference profile in most regions (e.g. us.anthropic.claude-haiku-4-5-*), NOT the bare foundation-model id — set the EXACT id verified in tasks.md 1.1."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "bedrock_inference_regions" {
  description = "Regions the Haiku 4.5 cross-region inference profile can route to. The ask-worker IAM must allow bedrock:InvokeModel on the foundation-model ARN in each, or InvokeModel returns AccessDenied. These are the us. profile's members, confirmed via get-inference-profile (tasks.md 1.1)."
  type        = list(string)
  default     = ["us-east-1", "us-east-2", "us-west-2"]
}

variable "ask_cooldown_seconds" {
  description = "Per-user cooldown between accepted /ask questions."
  type        = number
  default     = 60
}

variable "ask_max_question_chars" {
  description = "Reject an /ask question longer than this (caps input-token burn before the model runs)."
  type        = number
  default     = 300
}

variable "ask_max_tokens" {
  description = "Max output tokens for an /ask answer."
  type        = number
  default     = 700
}

variable "ask_max_tool_turns" {
  description = "Max model turns in the /ask tool-use loop before a final no-tool answer is forced."
  type        = number
  default     = 3
}

variable "ask_max_searches" {
  description = "Max parallel_search calls per /ask question."
  type        = number
  default     = 2
}

variable "ask_max_result_bytes" {
  description = "Cap on search-result bytes fed back to the model (re-billed every subsequent turn)."
  type        = number
  default     = 6000
}

variable "ask_parallel_timeout_ms" {
  description = "Client-side timeout on the Parallel search fetch, so a hung search can't burn the whole Lambda timeout."
  type        = number
  default     = 8000
}

variable "ask_timeout_reserve_ms" {
  description = "Milliseconds of the ask-worker's Lambda budget held back so it can still edit the Discord message after abandoning a slow answer. A Lambda timeout kills the process without running catch blocks, so without this reserve a slow model leaves the user on a permanent 'thinking...'. Must exceed one Discord PATCH round-trip."
  type        = number
  default     = 5000
}
