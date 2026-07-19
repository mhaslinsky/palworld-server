# ---------------------------------------------------------------------------
# Off-box observer for the two timers that run ON the game box: the backup job and
# the idle-shutdown watcher.
#
# Both run on the box, so every way they can die is invisible from outside: dead
# timer, expired IAM, full disk, failed force-save, replaced instance. A backup
# system nobody is watching is a backup system that has already stopped and not
# told you. The idle watcher is worse - it fails OPEN (any error counts as "players
# present"), so a dead one never stops the box and never complains; on 2026-07-19
# that cost ~16h of continuous billing after a reboot killed an un-enabled timer.
# This is the piece that makes both trustworthy rather than merely present.
#
# Keys off instance state on purpose: the box stops itself when empty, so "no
# backups while stopped" is correct, not a fault. Alarming on that would train
# everyone to ignore the alarm - which is how a real alert gets missed.
# ---------------------------------------------------------------------------

locals {
  monitor_name = "${var.project_name}-backup-monitor"
}

data "archive_file" "backup_monitor" {
  type        = "zip"
  source_dir  = "${path.module}/../discord-bot/backup-monitor"
  output_path = "${path.module}/.terraform/tmp/backup-monitor.zip"
}

data "aws_iam_policy_document" "backup_monitor_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup_monitor" {
  name               = local.monitor_name
  assume_role_policy = data.aws_iam_policy_document.backup_monitor_assume.json
}

resource "aws_iam_role_policy_attachment" "backup_monitor_logs" {
  role       = aws_iam_role.backup_monitor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "backup_monitor" {
  # DescribeInstances takes no resource-level permissions; scope it to the region.
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

  # Read-only on the backups: the monitor observes, it never writes or deletes.
  statement {
    sid       = "ListBackups"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  # The roster is read for its LastModifiedDate, not its contents: it is the only
  # off-box evidence that the idle watcher is still alive.
  statement {
    sid       = "ReadWebhookAndRoster"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.discord_webhook_url.arn, aws_ssm_parameter.roster.arn]
  }

  statement {
    sid       = "DecryptSecureString"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]
  }
}

resource "aws_iam_role_policy" "backup_monitor" {
  name   = local.monitor_name
  role   = aws_iam_role.backup_monitor.id
  policy = data.aws_iam_policy_document.backup_monitor.json
}

resource "aws_cloudwatch_log_group" "backup_monitor" {
  name              = "/aws/lambda/${local.monitor_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "backup_monitor" {
  function_name = local.monitor_name
  role          = aws_iam_role.backup_monitor.arn
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  architectures = ["arm64"]

  filename         = data.archive_file.backup_monitor.output_path
  source_code_hash = data.archive_file.backup_monitor.output_base64sha256

  timeout     = 30
  memory_size = 256

  environment {
    variables = {
      INSTANCE_ID   = aws_instance.server.id
      BACKUP_BUCKET = aws_s3_bucket.backups.id
      BACKUP_PREFIX = "world/linux/"
      STALE_MINUTES = "45" # the job runs every 30 min; 45 tolerates one missed run
      MIN_BYTES     = "1000000"
      WEBHOOK_PARAM = aws_ssm_parameter.discord_webhook_url.name

      # Idle-watcher liveness. The watcher rewrites the roster every 2 min, so 10
      # tolerates four missed cycles before alerting.
      ROSTER_PARAM         = aws_ssm_parameter.roster.name
      ROSTER_STALE_MINUTES = "10"
      # A cold boot runs SteamCMD before the REST API answers, and the watcher
      # publishes nothing until it does. Suppress the alert until the instance has
      # been up this long, or every normal start would raise a false alarm.
      BOOT_GRACE_MINUTES = "20"
    }
  }

  depends_on = [aws_cloudwatch_log_group.backup_monitor]
}

# Every 15 min: fast enough that a stopped backup surfaces well inside one play
# session, cheap enough to be irrelevant (~2,900 invocations/mo, free tier).
resource "aws_cloudwatch_event_rule" "backup_monitor" {
  name                = local.monitor_name
  description         = "Check that world backups are still being written"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_cloudwatch_event_target" "backup_monitor" {
  rule      = aws_cloudwatch_event_rule.backup_monitor.name
  target_id = "lambda"
  arn       = aws_lambda_function.backup_monitor.arn
}

resource "aws_lambda_permission" "backup_monitor_events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.backup_monitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.backup_monitor.arn
}

# --- Independent failure channel -----------------------------------------------
# The monitor's only alert path is the Discord webhook, so a broken webhook (bad
# token, 429, Discord outage) means it can detect missing backups and tell nobody.
# notify() now throws on a failed delivery, which fails the invocation - this is
# what turns that failure into something a human learns about, over a channel that
# does NOT depend on Discord being healthy.
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

# Opt-in: with no address set, the topic exists but nothing is subscribed, and the
# alarm is visible only in the console. Set alert_email in tfvars to get mail.
resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "backup_monitor_errors" {
  alarm_name          = "${local.monitor_name}-errors"
  alarm_description   = "The backup freshness monitor failed to run or could not deliver an alert."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.backup_monitor.function_name }
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  # Missing data is NOT success here: if the function stops being invoked at all,
  # that is itself the failure this alarm exists to catch.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

output "alerts_topic" {
  description = "SNS topic for monitor failures. Subscribe an address via var.alert_email (needs email confirmation)."
  value       = aws_sns_topic.alerts.arn
}

output "backup_monitor_logs" {
  description = "Tail the backup freshness monitor."
  value       = "aws logs tail /aws/lambda/${local.monitor_name} --follow --profile ${var.aws_profile} --region ${var.aws_region}"
}
