# Daily automated EBS snapshots of the root volume (which holds the world save).
# Retains the last 5 daily snapshots. Crash-recovery net per the setup research.
resource "aws_dlm_lifecycle_policy" "daily_snapshots" {
  description        = "${var.project_name} daily EBS snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    # Target the root volume by its Name tag (set in compute.tf).
    target_tags = {
      Name = "${var.project_name}-root"
    }

    schedule {
      name = "daily-5-retain"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:00"] # UTC
      }

      retain_rule {
        count = 5
      }

      tags_to_add = {
        SnapshotCreator = "dlm"
        Project         = var.project_name
      }

      copy_tags = true
    }
  }
}
