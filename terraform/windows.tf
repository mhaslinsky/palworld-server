# ---------------------------------------------------------------------------
# Windows migration — PARALLEL build (see AIDB 2026-07-11-windows-migration-plan).
#
# Everything here is additive and gated on var.enable_windows_migration. The live
# Linux instance (aws_instance.server) is NEVER referenced or modified by this file,
# so a plan/apply that stands up Windows leaves the running server untouched. The
# EIP stays on Linux until cutover (M3); the Windows box uses a temporary public IP.
#
# This file intentionally contains ONLY the OS-independent infrastructure (AMI, SG,
# save volume, backup). The instance + PowerShell user_data live in windows_instance.tf
# once the steamcmd/NSSM/UE4SS layout is verified — writing user_data from memory would
# risk a box that boots but never actually serves.
# ---------------------------------------------------------------------------

locals {
  windows_enabled = var.enable_windows_migration ? 1 : 0
  windows_name    = "${var.project_name}-windows"
}

# Latest AWS-published Windows Server 2022 base AMI, via the public SSM parameter.
data "aws_ssm_parameter" "windows_2022" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

# The subnet the Linux box already uses — the save volume must be in this subnet's AZ.
data "aws_subnet" "selected" {
  id = data.aws_subnets.default.ids[0]
}

# Dedicated SG for the Windows box so the live Linux instance's SG is never touched.
# Same public game port, but RDP (3389) instead of SSH for admin. REST/RCON stay closed.
resource "aws_security_group" "server_windows" {
  count       = local.windows_enabled
  name        = "${local.windows_name}-sg"
  description = "Palworld Windows server: game traffic in, RDP from admin only."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Palworld game traffic"
    from_port   = 8211
    to_port     = 8211
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # RDP for admin + mod uploads. Locked to the operator's IP (same var as SSH on Linux).
  # RCON (25575) and REST API (8212) are deliberately NOT opened — localhost only.
  ingress {
    description = "RDP (admin + mod uploads)"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "All outbound (SteamCMD, Windows Update, Discord webhook, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.windows_name}-sg" }
}

# BLOCKER 4: SaveGames on a dedicated, persistent volume that survives instance
# replacement. user_data_replace_on_change on the Windows instance must never be able
# to wipe the world — so the world does not live on the root volume.
resource "aws_ebs_volume" "windows_save" {
  count             = local.windows_enabled
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.windows_save_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${local.windows_name}-save" }

  lifecycle {
    prevent_destroy = true
  }
}

# BLOCKER 4: the save volume needs its own backup — the existing DLM policy only
# targets "${project_name}-root". Separate policy keyed on the Windows save tag.
resource "aws_dlm_lifecycle_policy" "windows_save_snapshots" {
  count              = local.windows_enabled
  description        = "${local.windows_name} save volume daily snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Name = "${local.windows_name}-save"
    }

    schedule {
      name = "daily-7-retain"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:30"] # UTC, offset from the root policy's 07:00
      }

      retain_rule {
        count = 7
      }

      tags_to_add = {
        SnapshotCreator = "dlm"
        Project         = var.project_name
      }

      copy_tags = true
    }
  }
}
