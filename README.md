# palworld-server

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
| **Auto-stop** (empty → off) | Local systemd timer on the box polls the Palworld REST API on `localhost` and runs `shutdown -h now` after 30 min of zero players. AWS then stops the instance. | ✅ in this Terraform |
| **Start** (Discord → on) | Whitelisted Discord slash command → Lambda (Ed25519-verified) → `ec2:StartInstances`. | ✅ deployed — see `discord-bot/` |
| **Presence** (bot status) | Always-on t4g.nano holding the Discord Gateway socket, so presence reads "sleeping" while the game box is stopped. | ✅ behind `enable_presence_bot` |

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

## Mods — Linux cannot run them; the Windows box can

Self-hosting is specifically so building mods work (managed hosts like GPORTAL block
them). **They do not load on the Linux dedicated server** — Palworld only supports
server-side mods on the Windows dedicated build, which is why `windows*.tf` exists.

Tested end-to-end on 2026-07-18 with "Less Restrictive Building" (Nexus mod 98), on the
Windows box, using the PAK variant (no UE4SS needed):

- The relaxed building is gated on **both sides**. A vanilla client on a modded server
  cannot place sky/no-collision builds, and a modded client on a vanilla server cannot
  either. So the server needs the `.pak` **and every player who wants to build needs it
  too** — a vanilla player can still join, see, and interact with modded structures.
- On the Windows box the `.pak`s live on the persistent `D:` volume
  (`D:\PalServer\mods`) and are copied into `Pal\Content\Paks\~mods` on every boot.
  They cannot be re-downloaded automatically: Nexus requires a login.

Expect mods to need updated builds right after any major Palworld patch — which is why
the Windows bootstrap deliberately does **not** run SteamCMD on every boot.

## Layout

```
terraform/           base server (Linux, live)
  compute.tf         EC2 instance, generated SSH keypair, root EBS
  network.tf         security group (8211/udp public, 22 admin-only), Elastic IP
  iam.tf             instance role (SSM Session Manager), DLM backup role
  backup.tf          daily EBS snapshots (retain 5) via Data Lifecycle Manager
  discord.tf         start-on-request Lambda + Function URL + billing alarm
  presence.tf        always-on presence daemon (enable_presence_bot)
  ssm.tf             roster + webhook parameters (the box's one-way channel out)
  user_data.sh.tftpl cloud-init: SteamCMD install, server config, idle timer
  variables.tf outputs.tf data.tf providers.tf versions.tf

  windows.tf              Windows migration: SG, persistent save volume, DLM
  windows_instance.tf     the parallel Windows game instance
  windows_user_data.ps1.tftpl  its bootstrap (MUST STAY PURE ASCII - see header)
scripts/
  idle-shutdown.sh   the localhost player-count poller (Linux, injected into user_data)
  palworld-launch.ps1  Windows launcher + watchdog (Scheduled Task)
  palworld-idle.ps1    Windows idle-shutdown watcher
discord-bot/
  src/               start-on-request bot (deployed)
  presence/          Gateway presence daemon
```

## Windows migration status

The Windows box is proven but **not yet production**: `palworld-idle.ps1` does not parse
on the box (emoji/em-dash in a BOM-less `.ps1` is read as ANSI by PowerShell 5.1), so
there is **no idle-shutdown there yet** and it must be stopped by hand or it bills
continuously. Cutover (final save copy, repointing the Lambda + presence daemon off the
Linux instance id, moving the Elastic IP) has not happened; Linux is still the live
server.
