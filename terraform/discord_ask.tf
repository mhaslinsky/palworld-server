# /ask — Palworld Q&A. The slow half of the Discord bot.
#
# The entry Lambda (discord.tf) verifies the signature, checks the allowlist, and
# claims the per-user cooldown, then async-invokes THIS worker, which runs a bounded
# Bedrock (Claude Haiku 4.5) tool-use loop with one Parallel AI web-search tool and
# edits the deferred Discord message with the answer.
#
# Why a separate function (not a branch of the entry Lambda): the worker needs a much
# longer timeout than the <3s public HTTP path can carry, and its own async retry
# policy. Lambda has no idle cost, so the split is ~free.

locals {
  ask_worker_name   = "${var.project_name}-discord-ask"
  parallel_key_name = "/${var.project_name}/parallel_api_key"

  # Haiku 4.5 is invoked through the `us.` cross-region inference profile, but Bedrock
  # authorizes InvokeModel against BOTH the profile ARN and the underlying regional
  # foundation-model ARNs — grant only one and you get AccessDenied. Derive both from
  # the model id (strip the `us.` profile prefix to get the foundation-model name) so
  # there is no account id to hardcode and the set stays in sync with bedrock_model_id.
  bedrock_foundation_model = trimprefix(var.bedrock_model_id, "us.")
  bedrock_model_arns = concat(
    ["arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"],
    [for region in var.bedrock_inference_regions : "arn:aws:bedrock:${region}::foundation-model/${local.bedrock_foundation_model}"],
  )
}

# --- Parallel AI key: a bot-identity-grade secret, same handling as the bot token ---
resource "aws_ssm_parameter" "parallel_api_key" {
  name  = local.parallel_key_name
  type  = "SecureString"
  value = var.parallel_api_key != "" ? var.parallel_api_key : "None"

  lifecycle {
    ignore_changes = [value] # set out-of-band; a placeholder here must not clobber it
  }
}

# --- Cooldown store: one row per user, self-cleaning via TTL --------------------
# On-demand billing: at friends-server volume this is effectively free, and there is
# no capacity to tune. The entry Lambda owns this table; the worker never touches it.
resource "aws_dynamodb_table" "ask_cooldown" {
  name         = "${var.project_name}-ask-cooldown"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = { Name = "${var.project_name}-ask-cooldown" }
}

# --- Worker function ------------------------------------------------------------
data "archive_file" "ask_worker" {
  type        = "zip"
  source_dir  = "${path.module}/../discord-bot/ask-worker"
  output_path = "${path.module}/.terraform/tmp/ask-worker.zip"
}

data "aws_iam_policy_document" "ask_worker_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ask_worker" {
  name               = local.ask_worker_name
  assume_role_policy = data.aws_iam_policy_document.ask_worker_assume.json
}

resource "aws_iam_role_policy_attachment" "ask_worker_logs" {
  role       = aws_iam_role.ask_worker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least privilege: invoke exactly the one model (via its cross-region inference
# profile AND the underlying regional foundation-model ARNs — Haiku 4.5 is invoked
# through the profile, but Bedrock authorizes against the regional model ARNs too, so
# BOTH are required or InvokeModel returns AccessDenied), and read the Parallel key.
# No DynamoDB: the worker never reads or writes the cooldown table.
data "aws_iam_policy_document" "ask_worker" {
  statement {
    sid       = "InvokeHaiku"
    actions   = ["bedrock:InvokeModel"]
    resources = local.bedrock_model_arns
  }

  statement {
    sid       = "ReadParallelKey"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.parallel_api_key.arn]
  }

  statement {
    sid       = "DecryptSecureString"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]
  }
}

resource "aws_iam_role_policy" "ask_worker" {
  name   = local.ask_worker_name
  role   = aws_iam_role.ask_worker.id
  policy = data.aws_iam_policy_document.ask_worker.json
}

resource "aws_cloudwatch_log_group" "ask_worker" {
  name              = "/aws/lambda/${local.ask_worker_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "ask_worker" {
  function_name = local.ask_worker_name
  role          = aws_iam_role.ask_worker.arn
  runtime       = "nodejs22.x"
  handler       = "index.handler"
  architectures = ["arm64"]

  filename         = data.archive_file.ask_worker.output_path
  source_code_hash = data.archive_file.ask_worker.output_base64sha256

  # Covers the bounded loop (<= a few Bedrock turns + <= 2 searches, each search
  # capped at ~8s) with margin, and stays far under Discord's 15-min edit window.
  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      MODEL_ID                = var.bedrock_model_id
      DISCORD_APP_ID          = var.discord_app_id
      PARALLEL_KEY_PARAM      = aws_ssm_parameter.parallel_api_key.name
      PARALLEL_SEARCH_URL     = var.parallel_search_url
      ASK_MAX_TOKENS          = tostring(var.ask_max_tokens)
      ASK_MAX_TOOL_TURNS      = tostring(var.ask_max_tool_turns)
      ASK_MAX_SEARCHES        = tostring(var.ask_max_searches)
      ASK_MAX_RESULT_BYTES    = tostring(var.ask_max_result_bytes)
      ASK_PARALLEL_TIMEOUT_MS = tostring(var.ask_parallel_timeout_ms)
      ASK_TIMEOUT_RESERVE_MS  = tostring(var.ask_timeout_reserve_ms)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ask_worker]
}

# Async invoke is AT-LEAST-ONCE: without this, a worker error (or a timeout) makes
# Lambda re-run the whole paid Bedrock/search loop up to 2 more times, and a retry can
# land after the 15-min interaction-token window (404 on the edit). Zero retries + the
# worker never throwing after it edits = each accepted /ask costs exactly one loop.
resource "aws_lambda_function_event_invoke_config" "ask_worker" {
  function_name          = aws_lambda_function.ask_worker.function_name
  maximum_retry_attempts = 0
}
