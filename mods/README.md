# Mods

`manifest.json` is the pinned source of truth for every mod on the estate: what the server
runs, what a client has to run, and what the published client modpack contains. Edit it
first, then deploy. Never the reverse, or the file becomes a second opinion instead of a
record.

## Why a client pack exists at all

ValheimPlus runs with `enforceMod = true`, so a client on any other version is kicked at
connect and the message does not say why. Four mods have to be on a player's machine and
they have to be the versions the server runs. Everything else (ServersideQoL and its
modules, Animal Feeding Trough) is server-side, so connecting is the whole install, and
console players are covered the same way.

A synced folder was considered and rejected. BepInEx loads every DLL it finds under
`plugins/`, and a cloud-sync conflict keeps both copies under different names, so one
conflicted sync leaves a player with two ValheimPlus DLLs and no say in which loads. The
sync also has no verification step, which is the same failure as rule 6 in AGENTS.md:
putting a file somewhere is not deploying it.

## Publishing the pack

One-time, before the first build:

1. Create a team at <https://thunderstore.io/settings/teams/>.
2. Put its name in `modpack.namespace` in `manifest.json`, replacing the placeholder.
   The build refuses to run until you do.

Every time after that:

```bash
node scripts/modpack-build.mts          # writes mods/modpack/ and a zip under dist/
```

The build confirms every pinned version actually exists on Thunderstore before writing
anything, so a typo in a version becomes a failed build rather than a pack that resolves
to nothing on a player's machine. `--offline` skips that check and says loudly that it
did.

Then upload `mods/modpack/dist/<name>-<version>.zip` at
<https://thunderstore.io/c/valheim/create/>. Players' managers offer the update on their
next launch.

`manifest.json`, `README.md` and `icon.png` under `mods/modpack/` are generated. Do not
hand-edit them; change `manifest.json` at the top of this directory and rebuild. The icon
is drawn from code in `scripts/png.mts` rather than checked in as a binary.

## Updating a mod

1. Change the version in `manifest.json`.
2. Bump `modpack.version_number`. Thunderstore will not accept a version it already has.
3. Deploy to the server, then run the verify step below and confirm it comes back CLEAN.
4. Build and upload the pack.

Do steps 3 and 4 close together. Between them the server and the published pack disagree,
and anyone who updates in that window is kicked.

## Verifying the box matches

```bash
ssh <box> 'cat /home/steam/valheim/BepInEx/LogOutput.log' | node scripts/mods-verify.mts
```

It reads the load log rather than listing the plugins folder, because a DLL sitting on
disk having failed to load looks exactly like one that worked. That is not hypothetical
here: ServersideQoL 2.0.4 sat in the folder logging a version-check failure every five
seconds while PortalProgression silently did nothing and ore flowed through portals
freely.

Exit codes are 0 for clean, 1 for drift, and 2 for a log it could not read. Entries with
no `plugin_name` are reported as unchecked and are deliberately excluded from the verdict,
so an unverifiable mod never contributes to a pass.

## Fields in manifest.json

| Field | Meaning |
| --- | --- |
| `side` | `both`, `server` or `client`. The pack is built from `both` and `client`. |
| `version` | What Thunderstore calls the release. This is what the pack pins. |
| `upstream_version` | The author's own version where it differs, e.g. ValheimPlus 0.10.1.0 is Thunderstore 10.1.0. |
| `plugin_name` / `plugin_version` | What BepInEx prints in its log, which is what the verifier compares. The loader is packaged as 5.4.2350 and logs 5.4.23.5. |
| `enforced` | The server kicks clients on a different version. |
| `artifact_sha256` | Hashes of specific DLLs, not of the Thunderstore zip. Do not compare them against an archive. |
| `verified` | When each side was last actually read, and how. |

A client-side mod with a null `thunderstore` fails the build rather than being quietly
left out of the pack, since a silently short pack would kick players with no explanation.
Animal Feeding Trough is the live example of a Nexus-only mod, and it is server-side
precisely so this never comes up.
