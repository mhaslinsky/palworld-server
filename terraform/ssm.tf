# SSM Parameter Store is the one-way channel out of the game server.
#
# The REST API that knows the player roster binds to localhost only, and the
# security group opens neither 8212 nor 25575 — so nothing outside the box can ask
# it anything. Instead the box PUSHES what it knows here, and the Lambda reads it.
# Inverting the direction keeps the admin password off the wire, which is the whole
# point of the local-watcher design.
#
# It also decouples the Discord webhook from user_data: because
# user_data_replace_on_change = true, a webhook baked into user_data would make
# rotating it destroy and rebuild the instance. Here it's a one-line CLI call.

locals {
  webhook_param_name = "/${var.project_name}/discord_webhook_url"
  roster_param_name  = "/${var.project_name}/roster"
}

# The AWS-managed key that encrypts SecureString parameters.
data "aws_kms_key" "ssm" {
  key_id = "alias/aws/ssm"
}

# SecureString: anyone holding this URL can post to the channel as the bot.
# The value is optional — an empty webhook makes every notification a silent no-op.
resource "aws_ssm_parameter" "discord_webhook_url" {
  name  = local.webhook_param_name
  type  = "SecureString"
  value = var.discord_webhook_url != "" ? var.discord_webhook_url : "None"

  # Set/rotate this out of band without a terraform run:
  #   aws ssm put-parameter --name /palworld-server/discord_webhook_url \
  #     --type SecureString --overwrite --value 'https://discord.com/api/webhooks/...'
  lifecycle {
    ignore_changes = [value]
  }
}

# Written by the instance every 2 min; read by the bot to answer /palworld-status.
# Seeded here so a Lambda read never faults on a missing parameter before first boot.
resource "aws_ssm_parameter" "roster" {
  name  = local.roster_param_name
  type  = "String"
  value = jsonencode({ count = 0, names = "", updated = 0 })

  lifecycle {
    ignore_changes = [value] # the instance owns this value
  }
}

# --- Instance permissions: read the webhook, publish the roster ---------------
data "aws_iam_policy_document" "instance_ssm" {
  statement {
    sid       = "ReadDiscordWebhook"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.discord_webhook_url.arn]
  }

  # SecureString decryption goes through the AWS-managed SSM key. IAM matches on the
  # KEY arn, never the alias arn — hence the lookup rather than a constructed string.
  statement {
    sid       = "DecryptSecureString"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]
  }

  statement {
    sid       = "PublishRoster"
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.roster.arn]
  }
}

resource "aws_iam_role_policy" "instance_ssm" {
  name   = "${var.project_name}-instance-ssm"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_ssm.json
}
