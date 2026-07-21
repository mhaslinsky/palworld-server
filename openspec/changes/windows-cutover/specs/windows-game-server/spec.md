## ADDED Requirements

### Requirement: Windows server serves the real world
The Windows dedicated server SHALL serve the pre-existing production world
(GUID `E02C5819443F44ED89133A6C03B43E25`), never a freshly generated empty world. Because
`palworld-launch.ps1` and `windows_user_data.ps1.tftpl` do not set `DedicatedServerName`,
the world save MUST be placed at `D:\PalServer\SaveGames\0\<GUID>\` AND
`DedicatedServerName=<GUID>` MUST be written into the Windows `GameUserSettings.ini` before
launch.

#### Scenario: Served world matches the migrated world
- **WHEN** the Windows server has started after the save-copy + GUID surgery
- **THEN** REST `GET /v1/api/info` reports `worldguid == E02C5819443F44ED89133A6C03B43E25`
- **AND** the migrated players and their levels are present in-world

#### Scenario: EIP is withheld until the world is verified
- **WHEN** the served world GUID does not match the expected GUID
- **THEN** the Elastic IP association MUST NOT be moved to the Windows instance and the
  cutover halts (fail closed — the empty-world trap)

### Requirement: Building mod loads and functions
The Windows server SHALL load UE4SS and the building mod so that sky/overlap building works
and placed structures persist. This is the hard gate: the cutover MUST NOT proceed if the
building mod is broken by the Palworld build that SteamCMD pulls during rebuild.

#### Scenario: Sky-build survives on the test world
- **WHEN** a client connects to the rebuilt Windows box on the throwaway test world
- **THEN** the client can place a structure in an otherwise-illegal position
- **AND** the structure persists after a save/reload

#### Scenario: Broken building mod halts cutover
- **WHEN** the rebuilt server fails to load UE4SS or the building mod, or sky-build fails
- **THEN** the migration halts at Phase A and the Palworld build/UE4SS pin is fixed before
  any world migration — the live Linux server is untouched

### Requirement: Pal-size mod is additive and non-blocking
The server SHOULD load `BaseWorkerPalSize50Percent_P.pak`, but its failure MUST NOT block
the cutover.

#### Scenario: Pal-size mod missing does not block
- **WHEN** the Pal-size mod fails to load while the building mod loads correctly
- **THEN** the mod is noted for later and the cutover proceeds

### Requirement: The Linux world is never mutated
The migration SHALL treat the Linux world as read-only: the world moves via an S3 copy only.
The Linux world EBS volume MUST NOT be detached, remounted, or written by this change, so
restarting the (stopped, not terminated) Linux instance restores the exact pre-cutover world.

#### Scenario: Rollback restores the pre-cutover world
- **WHEN** the Linux instance is restarted after cutover
- **THEN** it serves the identical world it served before cutover, with no data loss from
  the migration itself

### Requirement: Control plane targets the Windows instance
After cutover the Discord start-bot (`ec2:StartInstances` + `INSTANCE_ID`), `/status`,
the presence daemon, and the backup/liveness monitor SHALL reference the Windows instance id;
the monitor's backup prefix SHALL be `world/windows/`; and the roster SSM parameter read by
`/status`/presence/monitor SHALL be the one the Windows watcher writes.

#### Scenario: Discord start brings up the Windows box
- **WHEN** a permitted user runs `/palworld-start`
- **THEN** the Windows instance starts and `/status` + Discord presence reflect its state
  and roster

#### Scenario: Liveness monitor watches the Windows backups
- **WHEN** the Windows box publishes backups and roster
- **THEN** the monitor reads `world/windows/` freshness and the live roster, and does not
  false-alarm on the now-idle Linux prefix

### Requirement: Terraform apply never replaces the Linux instance
Every Terraform apply in this change SHALL be reviewed from a saved plan; an apply MUST NOT
show `aws_instance.server` (Linux) as replaced or destroyed, and MUST NOT be run with
`-auto-approve`.

#### Scenario: Plan is read before apply
- **WHEN** an apply is about to run
- **THEN** the saved plan is read, the `Plan:` line and every replace/destroy is quoted for
  confirmation, and the apply is aborted if `aws_instance.server` appears in the change set
