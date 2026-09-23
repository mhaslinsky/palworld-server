# Swap and a memory cap for valheim.service, kept on the box by SSM State Manager.
#
# On 2026-09-23 the 4 GB box ran out of memory with no swap and froze solid for 20
# minutes instead of letting systemd restart Valheim. This lives outside user_data
# because editing user_data stops and starts the live server on apply (AGENTS.md rule 5),
# and because an association re-runs on a rebuilt instance, where user_data edits never
# reach a running one.

resource "aws_s3_object" "linux_memory_guard_script" {
  bucket       = aws_s3_bucket.backups.id
  key          = "scripts/linux/memory-guard.mts"
  source       = "${path.module}/../scripts/memory-guard.mts"
  etag         = filemd5("${path.module}/../scripts/memory-guard.mts")
  content_type = "text/plain"
}

resource "aws_ssm_document" "memory_guard" {
  name            = "${var.project_name}-memory-guard"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Keep swap and the valheim.service memory cap in place"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "memoryGuard"
      inputs = {
        timeoutSeconds = "600"
        runCommand = [
          "set -e",
          # A script change becomes a document change, which re-runs the association now.
          "# memory-guard.mts md5 ${aws_s3_object.linux_memory_guard_script.etag}",
          "install -d -m 0755 /opt/valheim",
          "aws s3 cp s3://${aws_s3_bucket.backups.id}/scripts/linux/memory-guard.mts /opt/valheim/memory-guard.mts --region ${var.aws_region} --only-show-errors",
          "/usr/bin/node /opt/valheim/memory-guard.mts",
        ]
      }
    }]
  })
}

resource "aws_ssm_association" "memory_guard" {
  association_name    = "${var.project_name}-memory-guard"
  name                = aws_ssm_document.memory_guard.name
  document_version    = aws_ssm_document.memory_guard.latest_version
  schedule_expression = "rate(30 minutes)"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.server.id]
  }
}
