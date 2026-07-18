# ---------------------------------------------------------------------------
# Windows migration — the parallel game instance.
#
# Additive + gated on var.enable_windows_migration. Does NOT reference or modify
# aws_instance.server. Uses a temporary public IP (associate_public_ip_address) —
# the EIP stays on the live Linux box until cutover (M3).
#
# user_data was built up interactively first (several Windows steps came back
# unverified in research) and codified here only once each step was proven on the
# real box — 2026-07-18, including a confirmed in-game sky-build through the mod.
#
# Rebuild safety: BOTH the world and the mod .paks live on the persistent D: volume,
# so user_data_replace_on_change can rebuild this instance without losing either.
# The .paks cannot be fetched at boot (Nexus requires a login), which is exactly why
# they are staged on the volume rather than downloaded.
# ---------------------------------------------------------------------------

resource "aws_instance" "server_windows" {
  count         = local.windows_enabled
  ami           = nonsensitive(data.aws_ssm_parameter.windows_2022.value)
  instance_type = var.instance_type
  subnet_id     = data.aws_subnets.default.ids[0]
  key_name      = aws_key_pair.server.key_name

  vpc_security_group_ids = [aws_security_group.server_windows[0].id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # Temporary reachable address for the build/test phase (EIP stays on Linux).
  associate_public_ip_address = true

  # Lets `aws ec2 get-password-data` decrypt the RDP admin password with our key.
  get_password_data = true

  # Match the Linux box: a local shutdown STOPS (not terminates) so billing halts
  # and the separate save volume persists.
  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_type = "gp3"
    volume_size = var.windows_root_volume_gb
    encrypted   = true
    tags        = { Name = "${local.windows_name}-root" }
  }

  user_data = templatefile("${path.module}/windows_user_data.ps1.tftpl", {
    save_drive_letter   = "D"
    save_volume_label   = "PalSave"
    game_udp_port       = 8211
    max_players         = 16
    rest_api_port       = var.rest_api_port
    admin_password      = var.admin_password
    idle_minutes        = var.idle_shutdown_minutes
    warn_before_minutes = var.idle_warn_before_minutes
    server_name         = var.server_name
    aws_region          = var.aws_region

    # Windows runs on its own temporary IP until cutover; the EIP moves at M3, at
    # which point this announcement address becomes correct for players.
    server_address = "${aws_eip.server.public_ip}:8211"

    webhook_param = local.webhook_param_name
    roster_param  = local.roster_param_name

    # Mirrors the live Linux OptionSettings so behaviour is identical after cutover.
    option_settings = join(",", [
      "bAllowGlobalPalboxImport=True",
      "bAllowGlobalPalboxExport=True",
      "PalSpawnNumRate=2.000000",
      "BaseCampWorkerMaxNum=50",
      "BaseCampMaxNumInGuild=10",
      "DeathPenalty=Item",
      "PalEggDefaultHatchingTime=0.030000",
      "ServerName=\"${var.server_name}\"",
      "ServerPassword=\"${var.server_password}\"",
      "AdminPassword=\"${var.admin_password}\"",
      "PublicPort=8211",
      "RCONEnabled=True",
      "RCONPort=${var.rcon_port}",
      "RESTAPIEnabled=True",
      "RESTAPIPort=${var.rest_api_port}",
    ])

    # gzip+base64 so the scripts survive templating AND PowerShell parsing intact (a
    # literal here-string injection broke the assembled user_data's parse), while
    # staying under EC2's hard 16 KB user_data limit that plain base64 exceeded.
    launch_script_b64 = base64gzip(file("${path.module}/../scripts/palworld-launch.ps1"))
    idle_script_b64   = base64gzip(file("${path.module}/../scripts/palworld-idle.ps1"))
  })

  # Minimal bootstrap → cheap/safe to rebuild. The world lives on the SEPARATE
  # save volume (below), never the root volume, so a rebuild cannot wipe it.
  user_data_replace_on_change = true

  tags = { Name = local.windows_name }
}

# BLOCKER 4: attach the persistent SaveGames volume. Its own resource so instance
# replacement never destroys it (the volume also carries prevent_destroy in windows.tf).
resource "aws_volume_attachment" "windows_save" {
  count       = local.windows_enabled
  device_name = "xvdf"
  volume_id   = aws_ebs_volume.windows_save[0].id
  instance_id = aws_instance.server_windows[0].id

  # Don't let Terraform force-detach a busy volume on teardown; stop the instance first.
  stop_instance_before_detaching = true
}

output "windows_server_ip" {
  description = "Temporary public IP of the Windows game box (build/test phase; EIP moves here at cutover)."
  value       = try(aws_instance.server_windows[0].public_ip, "")
}

output "windows_password_command" {
  description = "Retrieve the Windows Administrator password for RDP."
  value       = try("aws ec2 get-password-data --instance-id ${aws_instance.server_windows[0].id} --priv-launch-key secrets/${var.project_name}.pem --region ${var.aws_region} --profile ${var.aws_profile} --query PasswordData --output text", "")
}

output "windows_ssm_command" {
  description = "Keyless PowerShell shell on the Windows box via SSM Session Manager."
  value       = try("aws ssm start-session --target ${aws_instance.server_windows[0].id} --region ${var.aws_region} --profile ${var.aws_profile}", "")
}
