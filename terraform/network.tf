resource "aws_security_group" "server" {
  name        = "${var.project_name}-sg"
  description = "Palworld server: game traffic in, SSH from admin only."
  vpc_id      = data.aws_vpc.default.id

  # Game traffic. The ONLY port that must face the internet for players to connect.
  ingress {
    description = "Palworld game traffic"
    from_port   = 8211
    to_port     = 8211
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH for admin + mod (UE4SS/.pak) uploads over SFTP. Locked to the operator's IP.
  # RCON (25575) and the REST API (8212) are deliberately NOT opened — they stay localhost-only.
  ingress {
    description = "SSH (admin + mod uploads)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "All outbound (SteamCMD, apt, Discord webhook)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

# Stable public address so players never need a new IP after a stop/start cycle.
#
# The allocation deliberately does NOT set `instance` — the association lives in its
# own resource below. Otherwise the EIP depends on the instance while the instance's
# user_data depends on the EIP's address (to announce the join address to Discord),
# which is a dependency cycle. Splitting them lets user_data read the address.
resource "aws_eip" "server" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-eip" }
}

resource "aws_eip_association" "server" {
  allocation_id = aws_eip.server.id
  instance_id   = aws_instance.server.id
}
