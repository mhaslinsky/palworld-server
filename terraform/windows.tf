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

  # The Windows box must NOT publish to the live server's roster parameter while
  # both are running: its watcher writes every 2 minutes, so presence and
  # /palworld-status would flap between the real world and this test world. It gets
  # its own parameter until cutover, when it inherits the real one along with the
  # Lambda and presence-daemon instance ids (M3).
  windows_roster_param_name = "/${var.project_name}/roster_windows"

  # The live game instance the control plane (EIP, Discord bot, backup monitor,
  # presence) targets. try() falls back to the Linux box so enable_windows_migration =
  # false (the rollback lever) still PLANS instead of erroring on an out-of-range [0]
  # index — server_windows is count-gated, aws_instance.server is not.
  active_game_instance_id = try(aws_instance.server_windows[0].id, aws_instance.server.id)
}

resource "aws_ssm_parameter" "roster_windows" {
  count = local.windows_enabled
  name  = local.windows_roster_param_name
  type  = "String"
  value = jsonencode({ count = 0, names = "", updated = 0 })

  lifecycle {
    ignore_changes = [value] # the instance owns this value
  }
}

# --- Bootstrap scripts, shipped via S3 rather than embedded in user_data --------
#
# Embedding them (gzip+base64) hit EC2's hard 16 KB user_data limit as soon as the
# watcher grew a save-verification step. Two other things make S3 the better home:
# a script edit no longer changes the user_data hash, so shipping one does not
# force an instance replacement; and the running box can re-pull a fixed script
# without a rebuild - which matters because user_data_replace_on_change is off.
resource "aws_s3_object" "windows_launch_script" {
  count        = local.windows_enabled
  bucket       = aws_s3_bucket.backups.id
  key          = "scripts/windows/palworld-launch.ps1"
  source       = "${path.module}/../scripts/palworld-launch.ps1"
  etag         = filemd5("${path.module}/../scripts/palworld-launch.ps1")
  content_type = "text/plain"
}

resource "aws_s3_object" "windows_idle_script" {
  count        = local.windows_enabled
  bucket       = aws_s3_bucket.backups.id
  key          = "scripts/windows/palworld-idle.ps1"
  source       = "${path.module}/../scripts/palworld-idle.ps1"
  etag         = filemd5("${path.module}/../scripts/palworld-idle.ps1")
  content_type = "text/plain"
}

resource "aws_s3_object" "windows_backup_script" {
  count        = local.windows_enabled
  bucket       = aws_s3_bucket.backups.id
  key          = "scripts/windows/backup-to-s3.ps1"
  source       = "${path.module}/../scripts/backup-to-s3.ps1"
  etag         = filemd5("${path.module}/../scripts/backup-to-s3.ps1")
  content_type = "text/plain"
}

# The instance may read its own bootstrap scripts, and write backups under its OWN
# prefix. Deliberately narrow: it cannot read or delete the world backups, and it
# cannot write into world/linux/* (the shared instance role would otherwise let a
# Windows-side bug publish objects the monitor counts as healthy Linux backups).
data "aws_iam_policy_document" "instance_scripts" {
  count = local.windows_enabled

  statement {
    sid     = "ReadBootstrapScripts"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.backups.arn}/scripts/windows/*",
    ]
  }

  # HeadObject is GetObject on the same resource - used to compare the download
  # against S3's ETag so a truncated bootstrap script is caught.
  statement {
    sid     = "WriteWindowsWorldBackups"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.backups.arn}/world/windows/*",
      "${aws_s3_bucket.backups.arn}/world/windows-degraded/*",
    ]
  }
}

resource "aws_iam_role_policy" "instance_scripts" {
  count  = local.windows_enabled
  name   = "${local.windows_name}-scripts"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_scripts[0].json
}

# The shared instance role can publish the LIVE roster but not this one, so without
# this the Windows watcher's publish would fail silently every 2 minutes.
data "aws_iam_policy_document" "instance_roster_windows" {
  count = local.windows_enabled

  statement {
    sid       = "PublishWindowsRoster"
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.roster_windows[0].arn]
  }
}

resource "aws_iam_role_policy" "instance_roster_windows" {
  count  = local.windows_enabled
  name   = "${local.windows_name}-roster"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_roster_windows[0].json
}

# Windows Server 2022 base AMI, PINNED.
#
# `/aws/service/ami-windows-latest/...` moves every Patch Tuesday, and the game
# instance's ami forces replacement - so leaving it unpinned means an unrelated
# apply silently rebuilds the game box: players dropped mid-session with no
# warning, and the rebuild re-runs SteamCMD and pulls whatever Palworld build is
# current, which the migration plan's BLOCKER 1 says can break the mod outright.
# This is the exact hazard class that destroyed the Linux world on 2026-07-18
# (there it was `most_recent = true` on the Ubuntu AMI); Ubuntu and AL2023 were
# pinned in response and this one was missed.
#
# To move to a newer Windows image, change this id deliberately and treat it as a
# planned rebuild.
locals {
  windows_ami_id = "ami-0ed0165f19a049904"
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
