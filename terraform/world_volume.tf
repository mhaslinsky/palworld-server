# ---------------------------------------------------------------------------
# The world lives HERE, not on the instance's root volume.
#
# This is the structural fix for the 2026-07-18 incident. The guards on the
# instance (prevent_destroy, delete_on_termination = false,
# user_data_replace_on_change = false) all reduce the CHANCE of a replacement -
# but they are one edit away from being removed, and two of them are refusals a
# future agent can delete in the same change that destroys the box. Separating the
# data from the instance is the only change that makes an instance replacement
# survivable rather than merely unlikely: rebuild the box freely, the world does
# not care.
#
# The Windows box has had this arrangement since it was built, and its world
# survived four instance replacements in one evening without a scratch. This gives
# the Linux box the same property.
# ---------------------------------------------------------------------------

resource "aws_ebs_volume" "world" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.world_volume_gb
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.project_name}-world" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "world" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.world.id
  instance_id = aws_instance.server.id

  # Never yank a mounted world out from under a running server.
  stop_instance_before_detaching = true
}

# The existing DLM policy targets "${project_name}-root", which will no longer hold
# the world once this volume is in service. Without its own policy the world would
# silently lose snapshot coverage the moment it moved.
resource "aws_dlm_lifecycle_policy" "world_snapshots" {
  description        = "${var.project_name} world volume snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Name = "${var.project_name}-world"
    }

    schedule {
      name = "twice-daily-10-retain"

      # Twice daily rather than the root policy's once: the original 07:00 UTC
      # schedule meant a server played in the evenings (ET) always had a recovery
      # point most of a day old. That is exactly what made the incident's fallback
      # 15 hours stale. The 30-minute S3 backups are the primary tier; these are the
      # crash-consistent second tier.
      create_rule {
        interval      = 12
        interval_unit = "HOURS"
        times         = ["07:00"] # UTC; the 12h interval gives 07:00 and 19:00
      }

      retain_rule {
        count = 10
      }

      tags_to_add = {
        SnapshotCreator = "dlm"
        Project         = var.project_name
      }

      copy_tags = true
    }
  }
}

output "world_volume_id" {
  description = "EBS volume holding the world save (survives instance replacement)."
  value       = aws_ebs_volume.world.id
}
