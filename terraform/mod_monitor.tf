# ---------------------------------------------------------------------------
# Watches the two mod drifts that live outside the box, so neither depends on somebody
# remembering to look: a pinned mod shipping a new version on Thunderstore, and the
# published client pack falling behind mods/manifest.json.
#
# The second is the one worth the infrastructure. ValheimPlus runs enforceMod, so a
# manifest bumped without a publish leaves every player on the old pack until one of
# them is kicked by a message that does not explain itself. Nothing else in this estate
# can see that: the box is correct, the manifest is correct, and the two are consistent
# with each other while the thing players actually install is stale.
#
# The pins are rendered HERE from the committed manifest rather than duplicated, so the
# monitor cannot disagree with what is in git. Only the string comparison lives in the
# Lambda.
#
# Unlike the backup monitor this ignores instance state on purpose. The box sleeps most
# of the time, and a mod that shipped while it slept still matters before the next start.
# ---------------------------------------------------------------------------

locals {
  mod_monitor_name = "${var.project_name}-mod-monitor"
  mods_manifest    = jsondecode(file("${path.module}/../mods/manifest.json"))

  # Only Thunderstore-hosted mods can be looked up. A Nexus mod has no API to ask, and
  # pretending otherwise would produce a permanent UNKNOWN nobody can clear.
  mod_pins = [
    for mod in local.mods_manifest.mods : {
      identifier = mod.thunderstore
      version    = mod.version
    }
    if mod.thunderstore != null
  ]

  mod_pack_identifier = "${local.mods_manifest.modpack.namespace}-${local.mods_manifest.modpack.name}"
  mod_pack_version    = local.mods_manifest.modpack.version_number
}

data "archive_file" "mod_monitor" {
  type        = "zip"
  source_dir  = "${path.module}/../discord-bot/mod-monitor"
  output_path = "${path.module}/.terraform/tmp/mod-monitor.zip"
}

data "aws_iam_policy_document" "mod_monitor_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mod_monitor" {
  name               = local.mod_monitor_name
  assume_role_policy = data.aws_iam_policy_document.mod_monitor_assume.json
}

resource "aws_iam_role_policy_attachment" "mod_monitor_logs" {
  role       = aws_iam_role.mod_monitor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read-only, and only the webhook. This function never touches the instance, the world
# volume, or the backups bucket, so it is not granted the ability to.
data "aws_iam_policy_document" "mod_monitor" {
  statement {
    sid       = "ReadDiscordWebhook"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.discord_webhook_url.arn]
  }
}

resource "aws_iam_role_policy" "mod_monitor" {
  name   = local.mod_monitor_name
  role   = aws_iam_role.mod_monitor.id
  policy = data.aws_iam_policy_document.mod_monitor.json
}

resource "aws_cloudwatch_log_group" "mod_monitor" {
  name              = "/aws/lambda/${local.mod_monitor_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "mod_monitor" {
  function_name = local.mod_monitor_name
  role          = aws_iam_role.mod_monitor.arn
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  architectures = ["arm64"]

  filename         = data.archive_file.mod_monitor.output_path
  source_code_hash = data.archive_file.mod_monitor.output_base64sha256

  # Ten packages, each one HTTPS round trip, run concurrently.
  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      PINS_JSON       = jsonencode(local.mod_pins)
      PACK_IDENTIFIER = local.mod_pack_identifier
      PACK_VERSION    = local.mod_pack_version
      WEBHOOK_PARAM   = aws_ssm_parameter.discord_webhook_url.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.mod_monitor]
}

# Every 6 hours. Mod drift is not urgent the way a dead backup is: nothing is being lost
# while a pin is stale. It re-alerts on every run rather than tracking state, so a stale
# pin nags four times a day until somebody deals with it, which is the point. Faster than
# this would train the channel to scroll past it.
resource "aws_cloudwatch_event_rule" "mod_monitor" {
  name                = local.mod_monitor_name
  description         = "Check pinned mods against Thunderstore and the published pack against the manifest"
  schedule_expression = "rate(6 hours)"
}

resource "aws_cloudwatch_event_target" "mod_monitor" {
  rule      = aws_cloudwatch_event_rule.mod_monitor.name
  target_id = "lambda"
  arn       = aws_lambda_function.mod_monitor.arn
}

resource "aws_lambda_permission" "mod_monitor_events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mod_monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.mod_monitor.arn
}

# The function throws when it cannot deliver to Discord, so a broken webhook surfaces
# here instead of vanishing. treat_missing_data breaching means a function that stops
# running at all also alarms, which is the failure a monitor cannot report about itself.
resource "aws_cloudwatch_metric_alarm" "mod_monitor_errors" {
  alarm_name          = "${local.mod_monitor_name}-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 21600
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_description   = "The mod monitor errored or stopped running. Its findings are not reaching Discord."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.mod_monitor.function_name
  }
}
