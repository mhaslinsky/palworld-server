data "aws_caller_identity" "current" {}

# Default VPC + a subnet in it — sufficient for a single public game server.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Canonical's official Ubuntu 22.04 LTS (jammy) AMI — most-documented base for SteamCMD + Palworld.
#
# PINNED to the id the live instance was launched from. With most_recent=true this
# data source drifts every time Canonical publishes a new jammy image, and because
# aws_instance.server.ami forces replacement, ANY `terraform apply` would then destroy
# and rebuild the running game server (world lives on its root volume). The image-id
# filter freezes it so the diff is a no-op. To intentionally move to a newer AMI, update
# the pinned id here and treat it as a deliberate (backup-first) instance replacement.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "image-id"
    values = ["ami-0d28727121d5d4a3c"]
  }

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
