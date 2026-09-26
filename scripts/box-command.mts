#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const AWS_PROFILE = "aidb-personal";
const AWS_REGION = "us-east-1";
const SERVER_TAG_FILTER = "Name=tag:Name,Values=palworld-server";
const BACKUP_COMMAND = "sudo -u steam /usr/bin/node /opt/valheim/valheim-backup.mts";
const DEFAULT_POLL_INTERVAL_MS = 5_000;
const DEFAULT_POLL_CEILING_MS = 600_000;
const AWS_CALL_TIMEOUT_MS = 30_000;

export interface ServerInstance {
  instanceId: string;
  stateName: string;
}

export interface Invocation {
  status: string;
  responseCode: number | null;
  stdout: string;
  stderr: string;
}

export interface CommandOutcome {
  exitCode: number;
  stdout: string;
  stderr: string;
  message: string | undefined;
}

export interface BoxCommandDependencies {
  awsRunner: (argumentsList: string[], timeoutMs?: number) => string | Promise<string>;
  sleep: (durationMs: number) => Promise<void>;
  now: () => number;
  pollIntervalMs: number;
  pollCeilingMs: number;
}

export interface OutputSink {
  stdout: (text: string) => void;
  stderr: (text: string) => void;
}

export type InvocationStatusKind = "poll" | "terminal" | "unknown";

export function parseInstances(responseText: string): ServerInstance[] {
  let response: unknown;
  try {
    response = JSON.parse(responseText);
  } catch {
    throw new Error("describe-instances returned invalid JSON");
  }

  if (typeof response !== "object" || response === null || !("Reservations" in response)) {
    throw new Error("describe-instances response has no Reservations array");
  }

  const reservations = (response as { Reservations: unknown }).Reservations;
  if (!Array.isArray(reservations)) {
    throw new Error("describe-instances response has no Reservations array");
  }

  const instances: ServerInstance[] = [];
  for (const reservation of reservations) {
    if (typeof reservation !== "object" || reservation === null || !("Instances" in reservation)) {
      throw new Error("describe-instances reservation has no Instances array");
    }
    const reservationInstances = (reservation as { Instances: unknown }).Instances;
    if (!Array.isArray(reservationInstances)) {
      throw new Error("describe-instances reservation has no Instances array");
    }

    for (const instance of reservationInstances) {
      if (typeof instance !== "object" || instance === null) {
        throw new Error("describe-instances returned an invalid instance");
      }
      const instanceRecord = instance as {
        InstanceId?: unknown;
        State?: { Name?: unknown };
      };
      if (
        typeof instanceRecord.InstanceId !== "string" ||
        typeof instanceRecord.State?.Name !== "string"
      ) {
        throw new Error("describe-instances returned an instance without its id or state");
      }
      instances.push({
        instanceId: instanceRecord.InstanceId,
        stateName: instanceRecord.State.Name,
      });
    }
  }

  return instances;
}

export function classifyInvocationStatus(status: string): InvocationStatusKind {
  switch (status) {
    case "Pending":
    case "InProgress":
    case "Delayed":
    case "Cancelling":
      return "poll";
    case "Success":
    case "Failed":
    case "TimedOut":
    case "Cancelled":
      return "terminal";
    default:
      return "unknown";
  }
}

export function invocationSucceeded(invocation: Invocation): boolean {
  return invocation.status === "Success" && invocation.responseCode === 0;
}

export function backupOutputVerified(stdoutText: string): boolean {
  const outputLines = stdoutText.split(/\r?\n/);
  const hasDegradedMarker = outputLines.some((outputLine) => /^BACKUP_DEGRADED(?:\s|$)/.test(outputLine));
  const hasVerifiedMarker = outputLines.some((outputLine) => /^BACKUP_VERIFIED \S+ \d+$/.test(outputLine));
  return hasVerifiedMarker && !hasDegradedMarker;
}

export function parseCommandId(responseText: string): string | undefined {
  const commandId = responseText.trim();
  return commandId === "" || commandId === "None" ? undefined : commandId;
}

export function parseInvocation(responseText: string): Invocation {
  let response: unknown;
  try {
    response = JSON.parse(responseText);
  } catch {
    throw new Error("get-command-invocation returned invalid JSON");
  }

  if (typeof response !== "object" || response === null || !("Status" in response)) {
    throw new Error("get-command-invocation response has no Status");
  }

  const invocationRecord = response as Record<string, unknown>;
  if (typeof invocationRecord.Status !== "string") {
    throw new Error("get-command-invocation response has no Status");
  }

  return {
    status: invocationRecord.Status,
    responseCode: typeof invocationRecord.ResponseCode === "number" ? invocationRecord.ResponseCode : null,
    stdout: typeof invocationRecord.StandardOutputContent === "string" ? invocationRecord.StandardOutputContent : "",
    stderr: typeof invocationRecord.StandardErrorContent === "string" ? invocationRecord.StandardErrorContent : "",
  };
}

function defaultAwsRunner(argumentsList: string[], timeoutMs = AWS_CALL_TIMEOUT_MS): string {
  return execFileSync("aws", argumentsList, {
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 1024 * 1024,
  });
}

function defaultSleep(durationMs: number): Promise<void> {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, durationMs));
}

export function defaultDependencies(): BoxCommandDependencies {
  return {
    awsRunner: defaultAwsRunner,
    sleep: defaultSleep,
    now: () => Date.now(),
    pollIntervalMs: DEFAULT_POLL_INTERVAL_MS,
    pollCeilingMs: DEFAULT_POLL_CEILING_MS,
  };
}

function awsArguments(commandArguments: string[]): string[] {
  return [...commandArguments, "--profile", AWS_PROFILE, "--region", AWS_REGION];
}

async function getServerInstances(dependencies: BoxCommandDependencies): Promise<ServerInstance[]> {
  const describeOutput = await dependencies.awsRunner(awsArguments([
    "ec2",
    "describe-instances",
    "--filters",
    SERVER_TAG_FILTER,
    "--output",
    "json",
  ]));
  return parseInstances(describeOutput);
}

function describeInstances(instances: ServerInstance[]): string {
  if (instances.length === 0) {
    return "STATE found 0 palworld-server instances";
  }

  const instanceList = instances.map((instance) => `${instance.instanceId} ${instance.stateName}`).join(", ");
  return `STATE found ${instances.length} palworld-server instances: ${instanceList}`;
}

function failedOutcome(message: string, invocation?: Invocation): CommandOutcome {
  return {
    exitCode: 1,
    stdout: invocation?.stdout ?? "",
    stderr: invocation?.stderr ?? "",
    message,
  };
}

function successfulOutcome(invocation: Invocation): CommandOutcome {
  return {
    exitCode: 0,
    stdout: invocation.stdout,
    stderr: invocation.stderr,
    message: undefined,
  };
}

export async function executeBoxCommand(
  command: string,
  dependencies: BoxCommandDependencies,
  requireBackupMarker = false,
): Promise<CommandOutcome> {
  if (
    !Number.isFinite(dependencies.pollIntervalMs) || dependencies.pollIntervalMs <= 0 ||
    !Number.isFinite(dependencies.pollCeilingMs) || dependencies.pollCeilingMs <= 0
  ) {
    return failedOutcome("poll interval and ceiling must be positive numbers");
  }

  const instances = await getServerInstances(dependencies);
  if (instances.length !== 1) {
    return failedOutcome(describeInstances(instances));
  }

  const instance = instances[0];
  if (instance === undefined) {
    return failedOutcome("STATE found 0 palworld-server instances");
  }
  if (instance.stateName !== "running") {
    return failedOutcome(`refusing to run command: ${instance.instanceId} is ${instance.stateName}, expected running`);
  }

  const sendOutput = await dependencies.awsRunner(awsArguments([
    "ssm",
    "send-command",
    "--instance-ids",
    instance.instanceId,
    "--document-name",
    "AWS-RunShellScript",
    "--parameters",
    JSON.stringify({ commands: [command] }),
    "--query",
    "Command.CommandId",
    "--output",
    "text",
  ]));
  const commandId = parseCommandId(sendOutput);
  if (commandId === undefined) {
    return failedOutcome("send-command returned no command id");
  }

  const pollStartedAt = dependencies.now();
  let lastInvocation: Invocation | undefined;
  while (true) {
    const remainingBeforePollMs = dependencies.pollCeilingMs - (dependencies.now() - pollStartedAt);
    if (remainingBeforePollMs <= 0) {
      return failedOutcome("command polling ceiling reached", lastInvocation);
    }

    const invocationOutput = await dependencies.awsRunner(awsArguments([
      "ssm",
      "get-command-invocation",
      "--command-id",
      commandId,
      "--instance-id",
      instance.instanceId,
      "--output",
      "json",
    ]), Math.min(AWS_CALL_TIMEOUT_MS, remainingBeforePollMs));
    const invocation = parseInvocation(invocationOutput);
    lastInvocation = invocation;

    if (dependencies.now() - pollStartedAt >= dependencies.pollCeilingMs) {
      return failedOutcome("command polling ceiling reached", invocation);
    }

    const statusKind = classifyInvocationStatus(invocation.status);
    if (statusKind === "unknown") {
      return failedOutcome(`unknown command invocation status: ${invocation.status}`, invocation);
    }
    if (statusKind === "terminal") {
      if (!invocationSucceeded(invocation)) {
        return failedOutcome(
          `command ended with Status=${invocation.status}, ResponseCode=${String(invocation.responseCode)}`,
          invocation,
        );
      }
      if (requireBackupMarker && !backupOutputVerified(invocation.stdout)) {
        const message = invocation.stdout.split(/\r?\n/).some((outputLine) => /^BACKUP_DEGRADED(?:\s|$)/.test(outputLine))
          ? "backup command printed BACKUP_DEGRADED"
          : "backup command did not print BACKUP_VERIFIED <key> <size>";
        return failedOutcome(message, invocation);
      }
      return successfulOutcome(invocation);
    }

    const remainingMs = dependencies.pollCeilingMs - (dependencies.now() - pollStartedAt);
    if (remainingMs <= 0) {
      return failedOutcome("command polling ceiling reached", invocation);
    }
    await dependencies.sleep(Math.min(dependencies.pollIntervalMs, remainingMs));
  }
}

function consoleSink(): OutputSink {
  return {
    stdout: (text) => process.stdout.write(text),
    stderr: (text) => process.stderr.write(text),
  };
}

function writeLine(write: (text: string) => void, text: string): void {
  write(`${text}\n`);
}

function writeOutcome(outcome: CommandOutcome, output: OutputSink): number {
  if (outcome.stdout !== "") {
    output.stdout(outcome.stdout);
  }
  if (outcome.stderr !== "") {
    output.stderr(outcome.stderr);
  }
  if (outcome.message !== undefined) {
    writeLine(output.stderr, outcome.message);
  }
  return outcome.exitCode;
}

export async function runCli(
  argumentsList: string[],
  dependencies: BoxCommandDependencies = defaultDependencies(),
  output: OutputSink = consoleSink(),
): Promise<number> {
  const [subcommand, ...commandParts] = argumentsList;
  try {
    if (subcommand === "state" && commandParts.length === 0) {
      const instances = await getServerInstances(dependencies);
      if (instances.length === 1) {
        const instance = instances[0];
        if (instance !== undefined) {
          writeLine(output.stdout, `STATE ${instance.instanceId} ${instance.stateName}`);
          return 0;
        }
      }
      writeLine(output.stderr, describeInstances(instances));
      return 1;
    }

    if ((subcommand === "run" && commandParts.length > 0) || (subcommand === "backup" && commandParts.length === 0)) {
      const command = subcommand === "backup" ? BACKUP_COMMAND : commandParts.join(" ");
      const outcome = await executeBoxCommand(command, dependencies, subcommand === "backup");
      return writeOutcome(outcome, output);
    }

    writeLine(output.stderr, "usage: node scripts/box-command.mts state | run <command> | backup");
    return 2;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    writeLine(output.stderr, `box command failed: ${message}`);
    return 1;
  }
}

const invokedScriptPath = process.argv[1];
if (invokedScriptPath !== undefined && import.meta.url === pathToFileURL(resolve(invokedScriptPath)).href) {
  process.exitCode = await runCli(process.argv.slice(2));
}
