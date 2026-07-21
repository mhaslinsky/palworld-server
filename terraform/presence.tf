# Discord presence daemon — the always-on half of the bot.
#
# Discord renders a bot's "Playing ..." status only while the bot holds an open
# Gateway WebSocket. A Lambda cannot: it is invoked, responds, and dies, and it is
# capped at 15 minutes. API Gateway's WebSocket support is for INBOUND client
# connections, not an outbound one to Discord. So presence requires a process that
# never stops — hence this t4g.nano, which runs even while the game server is off
# (that is precisely when presence should read "sleeping").
#
# It reads the same two facts the slash commands read: the game instance's EC2
# state, and the roster the game box publishes to SSM. It never contacts the game
# server, so Palworld's REST port stays bound to localhost.
#
# Cost: t4g.nano $3.07/mo + 8 GB gp3 $0.64 + public IPv4 $3.65 = ~$7.36/mo.
# The IPv4 is unavoidable: gateway.discord.gg publishes no AAAA record, so an
# IPv6-only host cannot reach it, and a NAT gateway costs more than this instance.

locals {
  presence_name        = "${var.project_name}-presence"
  bot_token_param_name = "/${var.project_name}/discord_bot_token"
}

# Amazon Linux 2023, arm64 — matches t4g (Graviton).
# PINNED to the launched id (same drift-replacement reason as data.aws_ami.ubuntu).
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "image-id"
    values = ["ami-0345f7445d5f4145d"]
  }

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# SecureString: a Discord bot token is a full takeover of the bot identity.
# Rotate with `aws ssm put-parameter --overwrite`; the daemon re-reads on restart.
resource "aws_ssm_parameter" "discord_bot_token" {
  name  = local.bot_token_param_name
  type  = "SecureString"
  value = var.discord_bot_token != "" ? var.discord_bot_token : "None"

  lifecycle {
    ignore_changes = [value]
  }
}

# --- Network: egress only. Nothing on the internet needs to reach this box. -----
resource "aws_security_group" "presence" {
  name        = local.presence_name
  description = "Palworld presence daemon: outbound only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound (Discord gateway, SSM, dnf, npm)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.presence_name }
}

# --- IAM: read the roster + the token, and look up one instance's state ---------
data "aws_iam_policy_document" "presence_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "presence" {
  name               = local.presence_name
  assume_role_policy = data.aws_iam_policy_document.presence_assume.json
}

# Session Manager, so this box needs no SSH key and no inbound port at all.
resource "aws_iam_role_policy_attachment" "presence_ssm_core" {
  role       = aws_iam_role.presence.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "presence" {
  statement {
    sid       = "ReadRosterAndToken"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.roster.arn, aws_ssm_parameter.discord_bot_token.arn]
  }

  statement {
    sid       = "DecryptSecureString"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_key.ssm.arn]
  }

  # DescribeInstances takes no resource-level permissions; scope it to the region.
  statement {
    sid       = "ReadGameServerState"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:Region"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_role_policy" "presence" {
  name   = local.presence_name
  role   = aws_iam_role.presence.id
  policy = data.aws_iam_policy_document.presence.json
}

resource "aws_iam_instance_profile" "presence" {
  name = local.presence_name
  role = aws_iam_role.presence.name
}

# --- The instance --------------------------------------------------------------
resource "aws_instance" "presence" {
  count = var.enable_presence_bot ? 1 : 0

  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = "t4g.nano"
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.presence.id]
  iam_instance_profile   = aws_iam_instance_profile.presence.name

  # Required: gateway.discord.gg is IPv4-only. Without this the daemon cannot connect.
  associate_public_ip_address = true

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
    tags        = { Name = "${local.presence_name}-root" }
  }

  user_data = templatefile("${path.module}/presence_user_data.sh.tftpl", {
    instance_id    = aws_instance.server_windows[0].id
    roster_param   = aws_ssm_parameter.roster.name
    server_address = "${aws_eip.server.public_ip}:8211"
    token_param    = aws_ssm_parameter.discord_bot_token.name
    aws_region     = var.aws_region

    presence_script = file("${path.module}/../discord-bot/presence/index.mjs")
  })

  user_data_replace_on_change = true

  tags = { Name = local.presence_name }
}

output "presence_instance_id" {
  description = "Presence daemon instance (empty when the bot is disabled)."
  value       = try(aws_instance.presence[0].id, "")
}

output "presence_logs_command" {
  description = "Tail the presence daemon's journal."
  value       = try("aws ssm start-session --target ${aws_instance.presence[0].id} --profile ${var.aws_profile} --region ${var.aws_region}", "")
}
