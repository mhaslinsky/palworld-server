import { strict as assert } from "node:assert";
import test from "node:test";
import { decide, extractNames, parseConf, parseIdleSince } from "./idle-logic.mts";

const commonInput = {
  nowSeconds: 2000,
  idleSince: 1000,
  warned: false,
  thresholdMin: 20,
  warnBeforeMin: 5,
};

test("decide returns unknown for a failed query", () => {
  assert.equal(decide({ ...commonInput, count: null }), "unknown");
});

test("decide returns reset only when the count is non-zero", () => {
  assert.equal(decide({ ...commonInput, count: 1 }), "reset");
  assert.notEqual(decide({ ...commonInput, count: 0 }), "reset");
  assert.notEqual(decide({ ...commonInput, count: null }), "reset");
});

test("decide starts the idle clock on the first empty observation", () => {
  assert.equal(decide({ ...commonInput, count: 0, idleSince: null }), "start_clock");
});

test("decide warns once before the threshold", () => {
  assert.equal(decide({ ...commonInput, count: 0 }), "warn");
});

test("decide shuts down at the threshold", () => {
  assert.equal(decide({ ...commonInput, count: 0, nowSeconds: 2200, idleSince: 1000 }), "shutdown");
});

test("decide waits after warning and before shutdown", () => {
  assert.equal(decide({ ...commonInput, count: 0, warned: true }), "wait");
});

test("parseIdleSince treats empty and invalid state as no clock", () => {
  assert.equal(parseIdleSince(""), null);
  assert.equal(parseIdleSince("abc"), null);
  assert.equal(parseIdleSince("  12345  "), 12345);
});

test("parseConf accepts spaces inside single-quoted values", () => {
  assert.deepEqual(
    parseConf("# Valheim watcher\nSERVER_LABEL='Valheim Friends'\nSERVER_ADDRESS='example.test:2457'\nQUERY_PORT='2457'\n"),
    {
      SERVER_LABEL: "Valheim Friends",
      SERVER_ADDRESS: "example.test:2457",
      QUERY_PORT: "2457",
    },
  );
});

test("extractNames finds default journal connect lines", () => {
  assert.equal(
    extractNames("Got character ZDOID from Alice :\nGot character ZDOID from Bob :\nGot character ZDOID from Alice :"),
    "Alice, Bob",
  );
});

test("extractNames supports injected patterns and returns an empty miss", () => {
  assert.equal(extractNames("connected player=Alice\n", [/player=([^\\s]+)/g]), "Alice");
  assert.equal(extractNames("server ready\n"), "");
});
