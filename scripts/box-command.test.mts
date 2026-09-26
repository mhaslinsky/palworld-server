#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";
import {
  defaultDependencies,
  runCli,
} from "./box-command.mts";
import type {
  BoxCommandDependencies,
  OutputSink,
} from "./box-command.mts";

interface TestHarness {
  dependencies: BoxCommandDependencies;
  calls: string[][];
  timeouts: Array<number | undefined>;
  sleeps: number[];
  output: OutputSink;
  stdoutText: () => string;
  stderrText: () => string;
}

function instance(instanceId: string, stateName: string): { InstanceId: string; State: { Name: string } } {
  return { InstanceId: instanceId, State: { Name: stateName } };
}

function describeResponse(reservations: Array<{ Instances: ReturnType<typeof instance>[] }>): string {
  return JSON.stringify({ Reservations: reservations });
}

function invocationResponse(
  status: string,
  responseCode: number | undefined,
  stdoutText = "",
  stderrText = "",
): string {
  return JSON.stringify({
    Status: status,
    ResponseCode: responseCode,
    StandardOutputContent: stdoutText,
    StandardErrorContent: stderrText,
  });
}

function createHarness(
  responses: Array<string | Error>,
  settings: { pollIntervalMs?: number; pollCeilingMs?: number } = {},
): TestHarness {
  const dependencyDefaults = defaultDependencies();
  const calls: string[][] = [];
  const timeouts: Array<number | undefined> = [];
  const sleeps: number[] = [];
  let virtualTimeMs = 0;
  let stdoutContent = "";
  let stderrContent = "";
  const dependencies: BoxCommandDependencies = {
    awsRunner: (argumentsList, timeoutMs) => {
      calls.push(argumentsList);
      timeouts.push(timeoutMs);
      const response = responses.shift();
      if (response === undefined) {
        throw new Error("unexpected AWS call");
      }
      if (response instanceof Error) {
        throw response;
      }
      return response;
    },
    sleep: async (durationMs) => {
      sleeps.push(durationMs);
      virtualTimeMs += durationMs;
    },
    now: () => virtualTimeMs,
    pollIntervalMs: settings.pollIntervalMs ?? 10,
    pollCeilingMs: settings.pollCeilingMs ?? 100,
  };
  const output: OutputSink = {
    stdout: (text) => {
      stdoutContent += text;
    },
    stderr: (text) => {
      stderrContent += text;
    },
  };

  return {
    dependencies: { ...dependencyDefaults, ...dependencies },
    calls,
    timeouts,
    sleeps,
    output,
    stdoutText: () => stdoutContent,
    stderrText: () => stderrContent,
  };
}

function runningServerResponse(): string {
  return describeResponse([{ Instances: [instance("i-12345678", "running")] }]);
}

function successfulRunResponses(stdoutText = "command output\n", stderrText = ""): string[] {
  return [
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Success", 0, stdoutText, stderrText),
  ];
}

function assertSubmittedCommandFailure(harness: TestHarness, commandId: string): void {
  assert.match(
    harness.stderrText(),
    new RegExp(`command ${commandId} was already submitted and must not be sent again`),
  );
  assert.equal(harness.calls.filter((argumentsList) => argumentsList.includes("send-command")).length, 1);
}

function assertInvocationPollCount(harness: TestHarness, expectedCount: number): void {
  assert.equal(
    harness.calls.filter((argumentsList) => argumentsList.includes("get-command-invocation")).length,
    expectedCount,
  );
}

test("state reports zero matching instances as a failure", async () => {
  const harness = createHarness([describeResponse([])]);

  const exitCode = await runCli(["state"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /found 0 palworld-server instances/);
});

test("state counts two instances in separate reservations", async () => {
  const responseText = describeResponse([
    { Instances: [instance("i-12345678", "running")] },
    { Instances: [instance("i-87654321", "stopped")] },
  ]);
  const harness = createHarness([responseText]);

  const exitCode = await runCli(["state"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /found 2 palworld-server instances/);
  assert.match(harness.stderrText(), /i-12345678 running, i-87654321 stopped/);
});

test("state counts two instances in one reservation", async () => {
  const responseText = describeResponse([{
    Instances: [instance("i-12345678", "running"), instance("i-87654321", "pending")],
  }]);
  const harness = createHarness([responseText]);

  const exitCode = await runCli(["state"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /found 2 palworld-server instances/);
});

test("state prints the sole instance id and state", async () => {
  const harness = createHarness([runningServerResponse()]);

  const exitCode = await runCli(["state"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  assert.equal(harness.stdoutText(), "STATE i-12345678 running\n");
});

test("run refuses a pending instance without sending a command", async () => {
  const harness = createHarness([describeResponse([{ Instances: [instance("i-12345678", "pending")] }])]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /is pending, expected running/);
  assert.equal(harness.calls.length, 1);
});

test("run refuses a stopping instance without sending a command", async () => {
  const harness = createHarness([describeResponse([{ Instances: [instance("i-12345678", "stopping")] }])]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /is stopping, expected running/);
  assert.equal(harness.calls.length, 1);
});

test("run refuses a stopped instance without sending a command", async () => {
  const harness = createHarness([describeResponse([{ Instances: [instance("i-12345678", "stopped")] }])]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /is stopped, expected running/);
  assert.equal(harness.calls.length, 1);
});

test("run refuses a shutting-down instance without sending a command", async () => {
  const harness = createHarness([describeResponse([{ Instances: [instance("i-12345678", "shutting-down")] }])]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /is shutting-down, expected running/);
  assert.equal(harness.calls.length, 1);
});

test("run refuses a terminated instance without sending a command", async () => {
  const harness = createHarness([describeResponse([{ Instances: [instance("i-12345678", "terminated")] }])]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /is terminated, expected running/);
  assert.equal(harness.calls.length, 1);
});

test("run refuses multiple matching instances without sending a command", async () => {
  const harness = createHarness([describeResponse([
    { Instances: [instance("i-12345678", "running")] },
    { Instances: [instance("i-87654321", "running")] },
  ])]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /found 2 palworld-server instances/);
  assert.equal(harness.calls.length, 1);
});

test("run accepts Success with response code zero", async () => {
  const harness = createHarness(successfulRunResponses());

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  assert.equal(harness.stdoutText(), "command output\n");
});

test("run retries InvocationDoesNotExist after send-command without resending", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    new Error("An error occurred (InvocationDoesNotExist) when calling GetCommandInvocation"),
    invocationResponse("Success", 0, "completed after registration\n"),
  ]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  assert.equal(harness.stdoutText(), "completed after registration\n");
  assert.equal(harness.calls.filter((argumentsList) => argumentsList.includes("send-command")).length, 1);
  assertInvocationPollCount(harness, 2);
});

test("run reports the submitted command when InvocationDoesNotExist persists to the polling ceiling", async () => {
  const invocationDoesNotExist = new Error(
    "An error occurred (InvocationDoesNotExist) when calling GetCommandInvocation",
  );
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationDoesNotExist,
    invocationDoesNotExist,
    invocationDoesNotExist,
  ], { pollIntervalMs: 10, pollCeilingMs: 25 });

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /command polling ceiling reached/);
  assertSubmittedCommandFailure(harness, "command-123");
  assertInvocationPollCount(harness, 3);
});

test("run reports the submitted command when invocation polling throws another AWS error", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    new Error("An error occurred (AccessDeniedException) when calling GetCommandInvocation"),
  ]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /AccessDeniedException/);
  assertSubmittedCommandFailure(harness, "command-123");
  assertInvocationPollCount(harness, 1);
});

test("run reports the submitted command when invocation output is invalid JSON", async () => {
  const harness = createHarness([runningServerResponse(), "command-123\n", "not-json"]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /get-command-invocation returned invalid JSON/);
  assertSubmittedCommandFailure(harness, "command-123");
  assertInvocationPollCount(harness, 1);
});

test("run rejects Success with a nonzero response code", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Success", 7, "partial output\n", "command failed\n"),
  ]);

  const exitCode = await runCli(["run", "false"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /Status=Success, ResponseCode=7/);
  assertSubmittedCommandFailure(harness, "command-123");
});

test("run rejects a Failed invocation", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Failed", 1),
  ]);

  const exitCode = await runCli(["run", "false"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /Status=Failed/);
  assertSubmittedCommandFailure(harness, "command-123");
});

test("run rejects a TimedOut invocation", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("TimedOut", 124),
  ]);

  const exitCode = await runCli(["run", "sleep 1"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /Status=TimedOut/);
  assertSubmittedCommandFailure(harness, "command-123");
});

test("run rejects a Cancelled invocation", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Cancelled", 1),
  ]);

  const exitCode = await runCli(["run", "false"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /Status=Cancelled/);
  assertSubmittedCommandFailure(harness, "command-123");
});

test("run rejects an unknown invocation status", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Mystery", 0),
  ]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /unknown command invocation status: Mystery/);
  assertSubmittedCommandFailure(harness, "command-123");
});

test("run polls Pending before accepting a terminal status", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Pending", undefined),
    invocationResponse("Success", 0, "Success after Pending\n"),
  ]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  assert.deepEqual(harness.sleeps, [10]);
  assertInvocationPollCount(harness, 2);
  assert.equal(harness.stdoutText(), "Success after Pending\n");
});

test("run polls InProgress before accepting a terminal status", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("InProgress", undefined),
    invocationResponse("Success", 0, "Success after InProgress\n"),
  ]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  assert.deepEqual(harness.sleeps, [10]);
  assertInvocationPollCount(harness, 2);
  assert.equal(harness.stdoutText(), "Success after InProgress\n");
});

test("run polls Delayed before accepting a terminal status", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Delayed", undefined),
    invocationResponse("Success", 0, "Success after Delayed\n"),
  ]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  assert.deepEqual(harness.sleeps, [10]);
  assertInvocationPollCount(harness, 2);
  assert.equal(harness.stdoutText(), "Success after Delayed\n");
});

test("run polls Cancelling before accepting a terminal status", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Cancelling", undefined),
    invocationResponse("Success", 0, "Success after Cancelling\n"),
  ]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  assert.deepEqual(harness.sleeps, [10]);
  assertInvocationPollCount(harness, 2);
  assert.equal(harness.stdoutText(), "Success after Cancelling\n");
});

test("run stops polling at one overall ceiling", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Pending", undefined),
    invocationResponse("Pending", undefined),
    invocationResponse("Pending", undefined, "last output\n", "last error\n"),
  ], { pollIntervalMs: 10, pollCeilingMs: 25 });

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /command polling ceiling reached/);
  assertSubmittedCommandFailure(harness, "command-123");
  assertInvocationPollCount(harness, 3);
  assert.deepEqual(harness.sleeps, [10, 10, 5]);
  assert.deepEqual(harness.timeouts.slice(2), [25, 15, 5]);
  assert.equal(harness.stdoutText(), "last output\n");
});

test("backup accepts a BACKUP_VERIFIED key and size line", async () => {
  const harness = createHarness(successfulRunResponses("BACKUP_VERIFIED world/linux/test.tgz 12345\n"));

  const exitCode = await runCli(["backup"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  const sendCall = harness.calls.find((argumentsList) => argumentsList.includes("send-command"));
  assert.ok(sendCall);
  assert.ok(sendCall.includes(JSON.stringify({
    commands: ["sudo -u steam /usr/bin/node /opt/valheim/valheim-backup.mts"],
  })));
});

test("backup rejects BACKUP_DEGRADED on stdout even when a verified marker is also present", async () => {
  const harness = createHarness(successfulRunResponses(
    "BACKUP_VERIFIED world/linux/test.tgz 12345\nBACKUP_DEGRADED world/linux-degraded/test.tgz 12345 - stale\n",
  ));

  const exitCode = await runCli(["backup"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /printed BACKUP_DEGRADED/);
  assertSubmittedCommandFailure(harness, "command-123");
});

test("backup rejects BACKUP_DEGRADED on stderr when stdout has a verified marker", async () => {
  const harness = createHarness(successfulRunResponses(
    "BACKUP_VERIFIED world/linux/test.tgz 12345\n",
    "BACKUP_DEGRADED world/linux-degraded/test.tgz 12345 - stale\n",
  ));

  const exitCode = await runCli(["backup"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /printed BACKUP_DEGRADED/);
  assertSubmittedCommandFailure(harness, "command-123");
});

test("backup rejects a successful invocation without a BACKUP_VERIFIED line", async () => {
  const harness = createHarness(successfulRunResponses("backup finished without marker\n"));

  const exitCode = await runCli(["backup"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /did not print BACKUP_VERIFIED/);
  assertSubmittedCommandFailure(harness, "command-123");
});

test("run fails when send-command returns no command id", async () => {
  const harness = createHarness([runningServerResponse(), "None\n"]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /send-command returned no command id/);
  assert.equal(harness.calls.length, 2);
});

test("run prints invocation stdout and stderr when the command fails", async () => {
  const harness = createHarness([
    runningServerResponse(),
    "command-123\n",
    invocationResponse("Failed", 1, "partial stdout\n", "diagnostic stderr\n"),
  ]);

  const exitCode = await runCli(["run", "false"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stdoutText(), /partial stdout/);
  assert.match(harness.stderrText(), /diagnostic stderr/);
});

test("every AWS call pins the profile and region and state lookup has no state filter", async () => {
  const harness = createHarness(successfulRunResponses());

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 0);
  assert.equal(harness.calls.length, 3);
  for (const argumentsList of harness.calls) {
    assert.ok(argumentsList.includes("--profile"));
    assert.ok(argumentsList.includes("aidb-personal"));
    assert.ok(argumentsList.includes("--region"));
    assert.ok(argumentsList.includes("us-east-1"));
  }
  assert.ok(harness.calls[0]?.includes("Name=tag:Name,Values=palworld-server"));
  const filtersIndex = harness.calls[0]?.indexOf("--filters") ?? -1;
  const outputIndex = harness.calls[0]?.indexOf("--output") ?? -1;
  assert.notEqual(filtersIndex, -1);
  assert.ok(outputIndex > filtersIndex);
  assert.deepEqual(harness.calls[0]?.slice(filtersIndex + 1, outputIndex), [
    "Name=tag:Name,Values=palworld-server",
  ]);
  assert.ok(harness.calls[1]?.includes("AWS-RunShellScript"));
});

test("run rejects malformed instance lookup output", async () => {
  const harness = createHarness(["not-json"]);

  const exitCode = await runCli(["run", "true"], harness.dependencies, harness.output);

  assert.equal(exitCode, 1);
  assert.match(harness.stderrText(), /invalid JSON/);
});
