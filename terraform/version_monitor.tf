# ---------------------------------------------------------------------------
# Off-box watcher for Palworld game updates.
#
# On 2026-08-12 Pocketpair patched at 03:01Z. Steam updated every player's client on
# its next launch; the server kept serving the build it had booted with; the first
# signal anyone got was a player hitting "version incompatible" at 2am. Nothing in
# the system knew a patch existed, and the box had been running the stale build for
# three hours by then.
#
# Unlike backup-monitor this deliberately does NOT key off instance state. The box
# stops itself when empty, so it is stopped most of the time, and a patch landing
# while it sleeps is exactly the thing worth knowing about before the next start.
# The installed build comes from an SSM parameter the on-box watcher publishes, which
# survives the box being down.
#
# It alerts. It does not update. See update-server.ps1's header for why an
# unattended updater is the wrong answer on a modded server.
# ---------------------------------------------------------------------------

locals {
  version_monitor_name        = "${var.project_name}-version-monitor"
  windows_build_param_name    = "/${var.project_name}/installed_build_windows"
  version_monitor_state_param = "/${var.project_name}/version_monitor_state"
}

# Seeded with buildid "0", which index.mjs treats as "nothing has published yet"
# rather than a real build. Without that sentinel the first run after a deploy would
# compare a live build against 0 and report the server as millions of builds behind.
resource "aws_ssm_parameter" "installed_build_windows" {
  count = local.windows_enabled
  name  = local.windows_build_param_name
  type  = "String"
  value = jsonencode({ buildid = "0", updated = 0 })

  lifecycle {
    ignore_changes = [value] # the instance owns this value
  }
}

# The on-box watcher publishes the installed build every cycle. Without this grant
# that publish fails every 2 minutes into its own catch block, and the monitor would
# report NO_DATA forever while every check looked green.
data "aws_iam_policy_document" "instance_build_windows" {
  count = local.windows_enabled

  statement {
    sid       = "PublishInstalledBuild"
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.installed_build_windows[0].arn]
  }
}

resource "aws_iam_role_policy" "instance_build_windows" {
  count  = local.windows_enabled
  name   = "${local.windows_name}-build"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_build_windows[0].json
}

# --- The monitor ----------------------------------------------------------------
#
# Every MANAGED resource below is count-gated on windows_enabled, because everything
# this monitor reads is Windows-side. The two data sources are not: an IAM policy
# document and a local zip cost nothing to evaluate when disabled, matching
# backup_monitor.tf. `enable_windows_migration` defaults to FALSE
# (variables.tf), and it is also the documented rollback lever, so an ungated monitor
# would deploy on a Linux-only stack with no build parameter to read, report UNKNOWN
# on every invocation, and nag Discord every 12h about a box that does not exist.
# A monitor that cannot observe its subject must not be deployed, rather than deployed
# and permanently complaining.

data "archive_file" "version_monitor" {
  type        = "zip"
  source_dir  = "${path.module}/../discord-bot/version-monitor"
  output_path = "${path.module}/.terraform/tmp/version-monitor.zip"
}

data "aws_iam_policy_document" "version_monitor_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "version_monitor" {
  count              = local.windows_enabled
  name               = local.version_monitor_name
  assume_role_policy = data.aws_iam_policy_document.version_monitor_assume.json
}

resource "aws_iam_role_policy_attachment" "version_monitor_logs" {
  count      = local.windows_enabled
  role       = aws_iam_role.version_monitor[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "version_monitor" {
  count = local.windows_enabled

  # No compact()/try() here any more: gating the whole monitor means the build
  # parameter always exists when this document does, so a silently-dropped ARN is
  # no longer possible. compact() would hide a broken reference as a shorter list.
  statement {
    sid     = "ReadWebhookAndBuild"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.discord_webhook_url.arn,
      aws_ssm_parameter.installed_build_windows[0].arn,
      aws_ssm_parameter.version_monitor_state[0].arn,
    ]
  }

  # Writes only its own dedupe record, so a standing "you are behind" nags on a
  # schedule instead of once per 30 minutes all night.
  statement {
    sid       = "WriteDedupeState"
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.version_monitor_state[0].arn]
  }

  statement {
    sid       = "DecryptSecureString"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]
  }
}

resource "aws_ssm_parameter" "version_monitor_state" {
  count = local.windows_enabled
  name  = local.version_monitor_state_param
  type  = "String"
  value = jsonencode({})

  lifecycle {
    ignore_changes = [value] # the Lambda owns this value
  }
}

resource "aws_iam_role_policy" "version_monitor" {
  count  = local.windows_enabled
  name   = local.version_monitor_name
  role   = aws_iam_role.version_monitor[0].id
  policy = data.aws_iam_policy_document.version_monitor[0].json
}

resource "aws_cloudwatch_log_group" "version_monitor" {
  count             = local.windows_enabled
  name              = "/aws/lambda/${local.version_monitor_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "version_monitor" {
  count         = local.windows_enabled
  function_name = local.version_monitor_name
  role          = aws_iam_role.version_monitor[0].arn
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  architectures = ["arm64"]

  filename         = data.archive_file.version_monitor.output_path
  source_code_hash = data.archive_file.version_monitor.output_base64sha256

  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      # Direct references, not try(): the gate above guarantees both exist whenever
      # this function does. A try() falling back to "" would ship a Lambda whose
      # BUILD_PARAM is empty and whose every run is UNKNOWN.
      BUILD_PARAM   = aws_ssm_parameter.installed_build_windows[0].name
      STATE_PARAM   = aws_ssm_parameter.version_monitor_state[0].name
      WEBHOOK_PARAM = aws_ssm_parameter.discord_webhook_url.name
      # The DEDICATED SERVER app. The client (1623730) is a separate app; what decides
      # whether the box is compatible is what the box installs.
      STEAM_APP_ID = "2394010"
      # While behind, re-alert this often. One alert that scrolls past at 3am and then
      # silence is indistinguishable from no problem.
      REMIND_HOURS = "12"
    }
  }

  depends_on = [aws_cloudwatch_log_group.version_monitor]
}

# Every 30 min. A patch is a rare event and nothing here is time-critical to the
# minute -- what matters is that it is found before the next play session, not
# within seconds. ~1,450 invocations/mo, inside the free tier.
resource "aws_cloudwatch_event_rule" "version_monitor" {
  count               = local.windows_enabled
  name                = local.version_monitor_name
  description         = "Alert when Steam's public Palworld build differs from the one installed on the server"
  schedule_expression = "rate(30 minutes)"
}

resource "aws_cloudwatch_event_target" "version_monitor" {
  count     = local.windows_enabled
  rule      = aws_cloudwatch_event_rule.version_monitor[0].name
  target_id = "lambda"
  arn       = aws_lambda_function.version_monitor[0].arn
}

resource "aws_lambda_permission" "version_monitor_events" {
  count         = local.windows_enabled
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.version_monitor[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.version_monitor[0].arn
}

# The Discord webhook is the only alert path, so a broken webhook means the monitor
# can detect a patch and tell nobody. notify() throws on a failed delivery, which
# fails the invocation -- this is what turns that into something a human hears about,
# over the SNS topic backup_monitor.tf already owns.
resource "aws_cloudwatch_metric_alarm" "version_monitor_errors" {
  count               = local.windows_enabled
  alarm_name          = "${local.version_monitor_name}-errors"
  alarm_description   = "The Palworld version monitor failed to run or could not deliver an alert."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.version_monitor[0].function_name }
  statistic           = "Sum"
  period              = 1800
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  # Missing data is NOT success: a function that stops being invoked at all is
  # itself the failure this alarm exists to catch.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Mirrors backup_monitor.tf's equivalent. The first time an alert fires is the worst
# moment to be working out the log group's name by hand.
output "version_monitor_logs_command" {
  description = "Tail the version monitor's logs."
  value       = try("aws logs tail /aws/lambda/${local.version_monitor_name} --follow --profile ${var.aws_profile} --region ${var.aws_region}", "")
}
