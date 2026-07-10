# pow-world-server

Terraform for a self-hosted **Palworld 1.0** dedicated server on AWS, for a 5-10
player friend group. On-demand and cheap: the server **auto-stops when empty** and
is meant to be started on request, so you pay for compute only while people play.

- **Account:** `aidb-personal` profile → `414700437904` (personal, **not** any CreditGenie account)
- **Region:** `us-east-1`
- **Instance:** `t3.xlarge` (4 vCPU / 16 GB — Pocketpair's recommended spec)
- **Baseline cost when stopped:** ~$7.60/mo (50 GB EBS + Elastic IP). Compute is ~$0.166/hr only while running.

## Architecture

Two halves, built in two phases:

| Half | Mechanism | Status |
|---|---|---|
| **Auto-stop** (empty → off) | Local systemd timer on the box polls the Palworld REST API on `localhost` and runs `shutdown -h now` after 25 min of zero players. AWS then stops the instance. | ✅ in this Terraform |
| **Start** (Discord → on) | Whitelisted Discord slash command → Lambda (Ed25519-verified) → `ec2:StartInstances`. | ⏳ phase 2 — see `discord-bot/` |

The auto-stop path runs entirely on the instance (no external Lambda, no NAT, no
network-exposed admin API) — this is deliberate; it was the outcome of a multi-model
critique that killed an earlier over-networked design. Full decision record lives in
AIDB: `_global/personal/palworld-server/2026-07-07-discord-ec2-control-plane-analysis.md`.

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit: admin_cidr, passwords
aws sso login --profile aidb-personal          # if the session is stale
terraform init
terraform plan
terraform apply
```

After apply, `terraform output` gives you the connect address, SSH command, and the
manual start/stop commands to use until the Discord bot exists.

## What players do

Connect in Palworld via **Join with IP** using the `connect_address` output
(`<elastic-ip>:8211`). The IP is stable (Elastic IP) so it never changes between sessions.

## Mods (UE4SS)

Self-hosting is specifically so UE4SS mods work (managed hosts like GPORTAL block them).
SSH in (`ssh_command` output) and drop `.pak` / UE4SS files under
`/home/steam/palworld/Pal/Content/Paks/` (or the UE4SS `Mods` dir). Expect UE4SS mods to
need updated builds right after any major Palworld patch.

## Layout

```
terraform/           base server (this is the 7/10 deliverable)
  compute.tf         EC2 instance, generated SSH keypair, root EBS
  network.tf         security group (8211/udp public, 22 admin-only), Elastic IP
  iam.tf             instance role (SSM Session Manager), DLM backup role
  backup.tf          daily EBS snapshots (retain 5) via Data Lifecycle Manager
  user_data.sh.tftpl cloud-init: SteamCMD install, server config, idle timer
  variables.tf outputs.tf data.tf providers.tf versions.tf
scripts/
  idle-shutdown.sh   the localhost player-count poller (injected into user_data)
discord-bot/         phase 2 — the start-on-request bot (not built yet)
```
