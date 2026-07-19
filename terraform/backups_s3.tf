# ---------------------------------------------------------------------------
# Off-box rolling world backups.
#
# Why this exists: on 2026-07-18 an instance replacement deleted the root volume
# and the world with it. The only surviving copy was a tarball that had been
# manually pulled to a laptop that morning - everything written to /tmp ON the box
# died with it. DLM snapshots existed but were up to 24h stale (the newest was
# 15h old), so the recovery point was a whole day of play behind.
#
# The rule this encodes: a backup that lives on the thing it is backing up is not
# a backup. These go to S3, on a 30-minute cadence, and survive the instance.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "backups" {
  bucket = "${var.project_name}-backups-${data.aws_caller_identity.current.account_id}"

  # The whole point is surviving the loss of everything else.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "${var.project_name}-backups" }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning so an overwrite or a delete is itself recoverable.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Retention: ~80 MB per backup at 48/day would be ~115 GB/mo unbounded. Expire the
# rolling copies after 14 days (~$1-2/mo steady state) and let the DLM snapshots
# cover anything older.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-rolling-backups"
    status = "Enabled"

    filter {
      prefix = "world/"
    }

    expiration {
      days = 14
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# The instance may WRITE backups and list them; it may not delete them. A box that
# can erase its own backup history is one bad script away from having none.
# --- Linux bootstrap scripts, shipped via S3 ------------------------------------
# Embedding them in user_data hit EC2's hard 16 KB limit once the backup script
# joined the idle watcher. Hosting them here also means a script fix no longer
# changes the user_data hash, so shipping one does not force an instance rebuild -
# which matters because user_data_replace_on_change is false and a rebuild is a
# player-facing event.
resource "aws_s3_object" "linux_idle_script" {
  bucket       = aws_s3_bucket.backups.id
  key          = "scripts/linux/idle-shutdown.sh"
  source       = "${path.module}/../scripts/idle-shutdown.sh"
  etag         = filemd5("${path.module}/../scripts/idle-shutdown.sh")
  content_type = "text/plain"
}

resource "aws_s3_object" "linux_backup_script" {
  bucket       = aws_s3_bucket.backups.id
  key          = "scripts/linux/backup-to-s3.sh"
  source       = "${path.module}/../scripts/backup-to-s3.sh"
  etag         = filemd5("${path.module}/../scripts/backup-to-s3.sh")
  content_type = "text/plain"
}

data "aws_iam_policy_document" "instance_backups" {
  # The box may read its own bootstrap scripts. Scoped to the scripts prefix: it
  # still cannot read or delete the world backups themselves.
  statement {
    sid       = "ReadBootstrapScripts"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.backups.arn}/scripts/linux/*"]
  }

  # Scoped to the LINUX prefixes, not all of world/*. Both instances share this
  # role, so a broad grant would let the Windows box write into the Linux backup
  # path - where a buggy script could publish junk that passes every freshness and
  # size check the monitor makes. Windows gets world/windows/* in windows.tf.
  #
  # linux-degraded/ is where a capture whose save could not be PROVEN goes: kept,
  # because on-disk state beats nothing, but deliberately outside the prefix the
  # monitor treats as healthy.
  statement {
    sid     = "WriteLinuxWorldBackups"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.backups.arn}/world/linux/*",
      "${aws_s3_bucket.backups.arn}/world/linux-degraded/*",
    ]
  }

  statement {
    sid       = "ListOwnBackups"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }
}

resource "aws_iam_role_policy" "instance_backups" {
  name   = "${var.project_name}-instance-backups"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_backups.json
}

output "backups_bucket" {
  description = "S3 bucket holding the rolling world backups."
  value       = aws_s3_bucket.backups.id
}

output "backups_list_command" {
  description = "List the most recent world backups."
  value       = "aws s3 ls s3://${aws_s3_bucket.backups.id}/world/ --profile ${var.aws_profile} --region ${var.aws_region} | tail -20"
}
