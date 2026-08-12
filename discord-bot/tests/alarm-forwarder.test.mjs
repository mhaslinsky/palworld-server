// Red/green harness for the SNS-to-Discord alarm forwarder.
//
//   cd discord-bot && npm install && npm test
//
// This function is the last link in the chain that carries "a monitor could not tell
// you something". Every way it can drop a message on the floor is therefore a way the
// whole alerting story ends in silence, so the failure paths matter more than the
// happy one and are what this file mostly exercises.

import {SSMClient} from "@aws-sdk/client-ssm";

let delivered = [];
let failDelivery = false;

function snsEvent(messages, subject) {
  return {Records: messages.map(message => ({Sns: {Message: message, Subject: subject}}))};
}

function alarmPayload({name = "palworld-server-version-monitor-errors", state = "ALARM",
                       reason = "Threshold Crossed: 1 datapoint [1.0]", description = "The monitor failed."} = {}) {
  return JSON.stringify({AlarmName: name, NewStateValue: state, NewStateReason: reason, AlarmDescription: description});
}

function install({webhook = "https://discord.test/webhook", fail = false} = {}) {
  delivered = [];
  failDelivery = fail;
  SSMClient.prototype.send = async () => ({Parameter: {Value: webhook}});
  global.fetch = async (_url, options) => {
    delivered.push(JSON.parse(options.body).content);
    if (failDelivery) return {ok: false, status: 500, statusText: "Internal Server Error"};
    return {ok: true, status: 200};
  };
}

process.env.ALARM_WEBHOOK_PARAM = "/palworld-server/discord_webhook_url";

const {handler} = await import("../alarm-forwarder/index.mjs");

let failures = 0;

async function expectOk(name, event, check) {
  let error = null;
  try {
    await handler(event);
  } catch (thrown) {
    error = thrown;
  }
  const passed = error === null && check();
  if (!passed) failures++;
  console.log(`${passed ? "PASS" : "FAIL"}  ${name}`);
  if (error) console.log(`      unexpected throw: ${error.message}`);
  for (const message of delivered) console.log(`      -> ${message.split("\n")[0].slice(0, 90)}`);
}

async function expectThrow(name, event) {
  let error = null;
  try {
    await handler(event);
  } catch (thrown) {
    error = thrown;
  }
  const passed = error !== null;
  if (!passed) failures++;
  console.log(`${passed ? "PASS" : "FAIL"}  ${name}`);
  console.log(`      ${error ? error.message.slice(0, 90) : "DID NOT THROW - the failure was swallowed"}`);
}

console.log("--- GREEN: an alarm becomes a readable Discord message ---");
install();
await expectOk("ALARM is forwarded with its reason",
  snsEvent([alarmPayload()]),
  () => delivered.length === 1
    && /is in ALARM/.test(delivered[0])
    && /Threshold Crossed/.test(delivered[0]));

// A channel that announces incidents but never recoveries leaves people believing the
// last thing they heard is still true.
install();
await expectOk("OK is forwarded too, as a recovery",
  snsEvent([alarmPayload({state: "OK", reason: "Threshold Crossed: 1 datapoint [0.0]"})]),
  () => delivered.length === 1 && /recovered/.test(delivered[0]));

// SNS carries anything published to the topic. A message this cannot parse is still a
// message someone meant to send, and dropping it would make this the silent link.
install();
await expectOk("a non-alarm message is still forwarded verbatim",
  snsEvent(["just a plain string"], "manual publish"),
  () => delivered.length === 1 && /just a plain string/.test(delivered[0]));
install();
await expectOk("JSON that is not an alarm is still forwarded",
  snsEvent(['{"hello":"world"}']),
  () => delivered.length === 1 && /hello/.test(delivered[0]));

console.log("\n--- Batches: one bad record must not lose the others ---");
install();
await expectOk("two alarms in one batch both deliver",
  snsEvent([alarmPayload({name: "alarm-one"}), alarmPayload({name: "alarm-two"})]),
  () => delivered.length === 2);

console.log("\n--- RED: every way to drop a message must fail loudly ---");
install({fail: true});
await expectThrow("webhook returns 500", snsEvent([alarmPayload()]));
install({webhook: "None"});
await expectThrow("webhook parameter unset (literal None)", snsEvent([alarmPayload()]));
// An empty batch means SNS invoked with nothing or the event shape changed. Returning
// quietly would make a broken integration look like a quiet night.
install();
await expectThrow("event contains no Records", {Records: []});
install();
await expectThrow("event is not an SNS event at all", {});
install();
await expectThrow("record has no Sns.Message string", {Records: [{Sns: {}}]});

console.log("\n--- RED: a partial batch failure must still report ---");
// Delivery attempts are collected rather than abandoned at the first failure, but the
// invocation must still fail so the Errors metric records it.
install({fail: true});
await expectThrow("both records fail", snsEvent([alarmPayload(), alarmPayload()]));
if (delivered.length !== 2) {
  console.log(`FAIL  expected 2 delivery ATTEMPTS, got ${delivered.length} - the first failure abandoned the rest`);
  failures++;
} else {
  console.log("PASS  every record was attempted despite the first failing");
}

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
