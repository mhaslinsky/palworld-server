# SSH keypair — generated locally so `terraform apply` is self-contained.
# The private key is written to ../secrets/<project>.pem (gitignored). Because it
# lives in local (gitignored) state, this is acceptable for a solo hobby project;
# do NOT reuse this pattern with remote/shared state.
resource "tls_private_key" "server" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "server" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.server.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.server.private_key_pem
  filename        = "${path.module}/../secrets/${var.project_name}.pem"
  file_permission = "0600"
}

resource "aws_instance" "server" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  subnet_id     = data.aws_subnets.default.ids[0]
  key_name      = aws_key_pair.server.key_name

  vpc_security_group_ids = [aws_security_group.server.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # Local `shutdown -h now` must STOP (not terminate) the instance so billing halts
  # but the world save on the root volume survives.
  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags        = { Name = "${var.project_name}-root" }
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    server_name     = var.server_name
    server_password = var.server_password
    admin_password  = var.admin_password
    rcon_port       = var.rcon_port
    rest_api_port   = var.rest_api_port
    idle_minutes    = var.idle_shutdown_minutes

    warn_before_minutes = var.idle_warn_before_minutes
    aws_region          = var.aws_region

    # Reading the EIP here is only possible because the association was split into
    # aws_eip_association — otherwise instance -> eip -> instance is a cycle.
    server_address = "${aws_eip.server.public_ip}:8211"

    # The watcher reads the webhook from SSM at runtime and publishes the roster back,
    # so neither value is baked into user_data (which would rebuild on every change).
    webhook_param = local.webhook_param_name
    roster_param  = local.roster_param_name

    # Injected verbatim as a value, so bash ${...} inside it is NOT re-interpolated by templatefile.
    idle_script = file("${path.module}/../scripts/idle-shutdown.sh")
  })

  # New user_data should rebuild the box (fine — world save is snapshotted by DLM; back up first for safety).
  user_data_replace_on_change = true

  tags = { Name = var.project_name }
}
