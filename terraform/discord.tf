# Discord start-bot: the START half of the control plane.
# (The STOP half runs on the instance itself — see scripts/idle-shutdown.sh.)
#
# Function URL auth is NONE because Discord cannot sign SigV4; the Lambda instead
# verifies every request's Ed25519 signature against the app's public key. That
# check is the ONLY thing standing between the public internet and this endpoint,
# so it runs before any parsing and before the allowlist. See the resource-policy
# note below: a NONE url needs two permission statements, not one.

locals {
  bot_name       = "${var.project_name}-discord-bot"
  bot_source_dir = "${path.module}/../discord-bot/src"
}

data "archive_file" "discord_bot" {
  type        = "zip"
  source_dir  = local.bot_source_dir
  output_path = "${path.module}/.terraform/tmp/discord-bot.zip"
}

# --- IAM: the function may start exactly one instance, and invoke only itself ---
data "aws_iam_policy_document" "discord_bot_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "discord_bot" {
  name               = local.bot_name
  assume_role_policy = data.aws_iam_policy_document.discord_bot_assume.json
}

resource "aws_iam_role_policy_attachment" "discord_bot_logs" {
  role       = aws_iam_role.discord_bot.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "discord_bot" {
  statement {
    sid       = "StartOnlyThisInstance"
    actions   = ["ec2:StartInstances"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.server_windows[0].id}"]
  }

  # DescribeInstances does not support resource-level permissions; AWS requires "*".
  # Scoped down with a condition on the region to keep the blast radius nominal.
  statement {
    sid       = "ReadInstanceState"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [var.aws_region]
    }
  }

  statement {
    sid       = "SelfInvokeWorker"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.discord_bot.arn]
  }

  # Read-only: the instance owns this value, the bot only reports it.
  statement {
    sid       = "ReadRoster"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.roster.arn]
  }
}

resource "aws_iam_role_policy" "discord_bot" {
  name   = local.bot_name
  role   = aws_iam_role.discord_bot.id
  policy = data.aws_iam_policy_document.discord_bot.json
}

# --- Function ---
resource "aws_cloudwatch_log_group" "discord_bot" {
  name              = "/aws/lambda/${local.bot_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "discord_bot" {
  function_name = local.bot_name
  role          = aws_iam_role.discord_bot.arn
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  architectures = ["arm64"]

  filename         = data.archive_file.discord_bot.output_path
  source_code_hash = data.archive_file.discord_bot.output_base64sha256

  # The worker path does StartInstances + a Discord API call; the HTTP path is
  # far quicker. 15s covers the slow path with room to spare.
  timeout = 15

  # Observed 120 MB peak at the 128 MB default — 94%, and an OOM would strand the
  # interaction at "thinking" forever. Billing is GB-seconds and more memory buys
  # proportionally more CPU, so at this volume the raise is ~free.
  memory_size = 256

  environment {
    variables = {
      DISCORD_PUBLIC_KEY = var.discord_public_key
      DISCORD_APP_ID     = var.discord_app_id
      INSTANCE_ID        = aws_instance.server_windows[0].id
      SERVER_ADDRESS     = "${aws_eip.server.public_ip}:8211"
      ALLOWED_USER_IDS   = join(",", var.discord_allowed_user_ids)
      ROSTER_PARAM       = aws_ssm_parameter.roster.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.discord_bot]
}

resource "aws_lambda_function_url" "discord_bot" {
  function_name      = aws_lambda_function.discord_bot.function_name
  authorization_type = "NONE" # Ed25519 signature verification is the gate; see header.
}

# A public function URL needs TWO resource-policy statements, not one. Since
# October 2025 Lambda requires both lambda:InvokeFunctionUrl AND lambda:InvokeFunction;
# with only the first it answers 403 (AccessDeniedException) and never invokes the
# function. See https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html
#
#   1. lambda:InvokeFunctionUrl  — created automatically by aws_lambda_function_url
#      above, as sid "FunctionURLAllowPublicAccess". Not managed here.
#   2. lambda:InvokeFunction, Condition Bool lambda:InvokedViaFunctionUrl=true —
#      sid "FunctionURLInvokeAllowPublicAccess". NOT expressible in aws provider 5.x
#      (`invoked_via_function_url` first appears in 6.x), so it is applied out of band:
#
#        aws lambda add-permission --function-name palworld-server-discord-bot \
#          --statement-id FunctionURLInvokeAllowPublicAccess \
#          --action lambda:InvokeFunction --principal '*' --invoked-via-function-url
#
# TODO: upgrade the aws provider to ~> 6.0 and bring statement 2 under terraform.
# Do that as its own change — a v6 bump re-plans the whole stack, EC2 included.
#
# This statement duplicates the action in (1) and grants nothing new. It is kept only
# so terraform holds a handle on the function's resource policy; delete it once the
# provider upgrade lands and (2) can be declared properly.
resource "aws_lambda_permission" "discord_bot_url" {
  statement_id           = "AllowPublicInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.discord_bot.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# --- Guardrail: catch a runaway bill regardless of what the bot does ---
resource "aws_cloudwatch_metric_alarm" "estimated_charges" {
  count = var.billing_alarm_usd > 0 ? 1 : 0

  alarm_name          = "${var.project_name}-estimated-charges"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.billing_alarm_usd
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600 # 6h — the fastest EstimatedCharges actually publishes
  statistic           = "Maximum"
  dimensions          = { Currency = "USD" }

  alarm_description = format("Estimated AWS charges exceeded $%s.", var.billing_alarm_usd)

  # NOTE: AWS/Billing metrics exist ONLY in us-east-1. This alarm is silent unless
  # var.aws_region is us-east-1 (it is, by default).
}
