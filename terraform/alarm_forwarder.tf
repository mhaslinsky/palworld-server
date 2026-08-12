# ---------------------------------------------------------------------------
# Forwards SNS alarm notifications into Discord.
#
# The monitors alert to Discord themselves; this is for the case where a monitor
# CANNOT alert -- it crashed, lost its IAM, or stopped being invoked at all (both
# alarms use treat_missing_data = "breaching", so silence trips them). Without this,
# those alarms reached only the CloudWatch console and the email subscription.
#
# READ THE LIMIT: it posts to the SAME webhook the monitors use, by explicit choice
# (Mike, 2026-08-12). That makes one case circular -- a dead webhook means the monitor
# cannot alert, the alarm fires, and this forwarder tries the same dead webhook. The
# email subscription on this topic is what actually covers that case, which is why
# both exist rather than either alone. ALARM_WEBHOOK_PARAM is a separate variable
# precisely so pointing it at a second webhook later is a config change, not a code one.
#
# SNS cannot post to Discord directly: AWS Chatbot supports Slack/Teams/Chime but not
# Discord, and a raw HTTPS subscription sends an envelope Discord rejects plus a
# confirmation handshake it will never complete. Hence a function.
# ---------------------------------------------------------------------------

locals {
  alarm_forwarder_name = "${var.project_name}-alarm-forwarder"
}

data "archive_file" "alarm_forwarder" {
  type        = "zip"
  source_dir  = "${path.module}/../discord-bot/alarm-forwarder"
  output_path = "${path.module}/.terraform/tmp/alarm-forwarder.zip"
}

data "aws_iam_policy_document" "alarm_forwarder_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alarm_forwarder" {
  name               = local.alarm_forwarder_name
  assume_role_policy = data.aws_iam_policy_document.alarm_forwarder_assume.json
}

resource "aws_iam_role_policy_attachment" "alarm_forwarder_logs" {
  role       = aws_iam_role.alarm_forwarder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read-only, and only the webhook. This function forwards; it observes nothing and
# owns no state, so it needs nothing else.
data "aws_iam_policy_document" "alarm_forwarder" {
  statement {
    sid       = "ReadWebhook"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.discord_webhook_url.arn]
  }

  statement {
    sid       = "DecryptSecureString"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]
  }
}

resource "aws_iam_role_policy" "alarm_forwarder" {
  name   = local.alarm_forwarder_name
  role   = aws_iam_role.alarm_forwarder.id
  policy = data.aws_iam_policy_document.alarm_forwarder.json
}

resource "aws_cloudwatch_log_group" "alarm_forwarder" {
  name              = "/aws/lambda/${local.alarm_forwarder_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "alarm_forwarder" {
  function_name = local.alarm_forwarder_name
  role          = aws_iam_role.alarm_forwarder.arn
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  architectures = ["arm64"]

  filename         = data.archive_file.alarm_forwarder.output_path
  source_code_hash = data.archive_file.alarm_forwarder.output_base64sha256

  # 30, not 15, and the arithmetic is the reason: each Discord POST can wait up to 8s
  # and records are delivered sequentially, so 15 could expire mid-batch, SNS would
  # retry the WHOLE event, and already-posted alarms would repeat. SNS-to-Lambda
  # currently delivers one record per invocation, which makes this defensive rather
  # than load-bearing, but the timeout should not be the thing standing between a
  # correct loop and a duplicate-alert storm.
  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      ALARM_WEBHOOK_PARAM = aws_ssm_parameter.discord_webhook_url.name
    }
  }

  # The IAM grants too, not just the log group. They are separate graph branches, so
  # terraform was free to create the function, its invoke permission, and the SNS
  # subscription while the policies were still attaching - leaving a live subscription
  # pointed at a function that cannot read the webhook. A partial apply would then look
  # subscribed and deliver nothing, which is the failure this whole path exists to
  # report on someone else's behalf.
  depends_on = [
    aws_cloudwatch_log_group.alarm_forwarder,
    aws_iam_role_policy.alarm_forwarder,
    aws_iam_role_policy_attachment.alarm_forwarder_logs,
  ]
}

resource "aws_sns_topic_subscription" "alerts_discord" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alarm_forwarder.arn

  # Ordered AFTER the invoke permission, or terraform is free to subscribe first and an
  # alarm published during the apply reaches a function SNS is not yet allowed to call.
  # SNS retries would probably cover it, but "probably recovered by a retry" is a poor
  # guarantee for the channel that carries "a monitor could not tell you something".
  depends_on = [aws_lambda_permission.alarm_forwarder_sns]
}

resource "aws_lambda_permission" "alarm_forwarder_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alarm_forwarder.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# Deliberately NO CloudWatch alarm on this function's own Errors metric. It would be
# an alarm whose only notification path is the topic this function subscribes to, so a
# forwarder that cannot deliver would raise an alarm that routes straight back into
# the forwarder that cannot deliver. The email subscription is the non-circular
# channel; this one is best-effort by construction and says so rather than wearing a
# guarantee it cannot keep.

# The whole "Discord is fine because email covers the circular case" argument rests on
# email ACTUALLY being subscribed, and alert_email is optional with an empty default.
# Deployed without it, this forwarder is the only subscriber and the alarm's sole path
# runs through the very webhook whose failure the alarm exists to report. That is a
# configuration in which the alerting looks complete and is not, so it warns rather
# than being left to a paragraph nobody rereads.
#
# A `check` rather than a precondition on purpose: this must not block an apply. A
# Discord-only alarm channel is still better than none, and a guard that blocks
# legitimate work gets removed.
check "alarm_channel_independence" {
  assert {
    # NOT just "is an address configured". An SNS email subscription delivers NOTHING
    # until its confirmation link is clicked, and terraform creates it in exactly that
    # state - so asserting the address alone passes while the channel is inert, which
    # is this repo's house bug wearing a guard's clothes. Observed live on 2026-08-12:
    # the subscription sat at PendingConfirmation for an hour after a successful apply.
    #
    # pending_confirmation is the provider attribute that answers the real question.
    # try(..., true) covers alert_email being unset, where the subscription does not
    # exist at all and the honest answer is "no independent channel".
    condition     = var.alert_email != "" && !try(aws_sns_topic_subscription.alerts_email[0].pending_confirmation, true)
    error_message = "The alerts topic has no CONFIRMED independent subscriber, so the Discord forwarder is its only working path. A dead Discord webhook then breaks the monitor AND its alarm, which is the exact case the SNS path exists for. Set alert_email, then click the confirmation mail AWS sends: an unconfirmed subscription delivers nothing. Verify with: aws sns list-subscriptions-by-topic --topic-arn <alerts topic> (a real ARN means confirmed; the literal string PendingConfirmation means it is not)."
  }
}

output "alarm_forwarder_logs_command" {
  description = "Tail the SNS-to-Discord alarm forwarder's logs."
  value       = "aws logs tail /aws/lambda/${local.alarm_forwarder_name} --follow --profile ${var.aws_profile} --region ${var.aws_region}"
}
