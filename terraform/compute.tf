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
  # while both EBS volumes - root and the world volume - survive.
  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags        = { Name = "${var.project_name}-root" }

    # The world now lives on aws_ebs_volume.world, not here - but this stays
    # false as a second line of defence. On 2026-07-18 an instance replacement
    # deleted this volume while it still held the world and took ~4.5 hours of
    # the group's progress with it. Orphaning it costs cents and makes that
    # failure recoverable by reattaching instead of unrecoverable.
    delete_on_termination = false
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

    # The watcher and backup scripts are FETCHED from S3 at boot, not embedded:
    # embedding both blew EC2's hard 16 KB user_data limit, and hosting them means
    # a script fix no longer changes the user_data hash (so it cannot force a
    # player-facing instance rebuild just to deploy a one-line change).
    backup_bucket = aws_s3_bucket.backups.id

    # Game-balance settings belong in code, not applied by hand to a running box.
    # These were runtime `sed` edits until 2026-07-18, so when the instance was
    # replaced the server came back at ENGINE DEFAULTS - which drops the base Pal
    # cap from 50 to 15 and ejects every Pal over it onto the ground. Everything
    # here must end with a trailing comma: it is spliced in front of the rest of
    # the single-line OptionSettings tuple.
    game_settings = join("", [
      "bAllowGlobalPalboxImport=True,",
      "bAllowGlobalPalboxExport=True,",
      "PalSpawnNumRate=2.000000,",
      "BaseCampWorkerMaxNum=50,",
      "BaseCampMaxNumInGuild=10,",
      "DeathPenalty=Item,",
      "PalEggDefaultHatchingTime=0.030000,",
    ])
  })

  # Leave this false.
  #
  # It was true until 2026-07-18, when a one-word fix to a COMMENT in
  # user_data.sh.tftpl changed the rendered script's hash, replaced this instance,
  # and deleted the world with its root volume - about 4.5 hours of the group's
  # progress, gone. Terraform cannot tell an inert comment from a real change.
  #
  # The world now lives on its own volume, so a replacement is survivable rather
  # than fatal - but it still drops every player mid-session and re-runs SteamCMD
  # into whatever build is current, so it stays a deliberate act.
  #
  # With this false, boot-script edits no longer apply automatically: apply them
  # on the box (SSM) or do a DELIBERATE, backup-first replacement.
  user_data_replace_on_change = false

  lifecycle {
    # Replacement is no longer world-destroying (the world is on its own volume),
    # but it is still player-facing downtime plus an unplanned game update. Make
    # Terraform refuse and error out rather than doing it quietly; removing this
    # flag is the explicit, two-step opt-in required to rebuild the box on purpose.
    prevent_destroy = true
  }

  tags = { Name = var.project_name }
}
