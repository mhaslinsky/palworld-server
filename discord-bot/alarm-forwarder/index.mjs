// Forwards CloudWatch alarm notifications from SNS into Discord.
//
// READ THIS BEFORE TRUSTING IT: this forwarder posts to the SAME webhook the monitors
// themselves use. That is a deliberate choice (Mike, 2026-08-12) and it costs a real
// guarantee, so the limit is written down rather than discovered later.
//
// The SNS path exists because a broken Discord webhook is itself one of the failures
// worth surfacing: backup-monitor and version-monitor both THROW when a Discord
// delivery fails, precisely so the invocation errors and the alarm fires over a
// channel that does not depend on Discord. Routing that alarm back through the same
// webhook makes that specific case circular -- webhook dies, monitor cannot alert,
// alarm fires, this forwarder tries the same dead webhook, nobody hears anything.
//
// What it DOES still cover, which is most of the alarm's value:
//   - the monitor Lambda crashing for a reason unrelated to Discord (a bug, revoked
//     IAM, an SSM read failing)
//   - the monitor not running AT ALL: both alarms use treat_missing_data =
//     "breaching", so a deleted function, a broken EventBridge rule, or a disabled
//     schedule trips them
//   - an alarm returning to OK, so a resolved incident says so
//
// What it does NOT cover: a dead or misconfigured Discord webhook. If that
// independence is wanted later, point ALARM_WEBHOOK_PARAM at a SECOND webhook in a
// different channel; the code already reads its own parameter for exactly that reason.

import {SSMClient, GetParameterCommand} from "@aws-sdk/client-ssm";

const REGION = process.env.AWS_REGION || "us-east-1";
// Deliberately its own variable rather than reusing the monitors' WEBHOOK_PARAM, so
// pointing this at a separate channel later is a terraform change and not a code one.
const ALARM_WEBHOOK_PARAM = process.env.ALARM_WEBHOOK_PARAM;

const ssm = new SSMClient({region: REGION});

// Discord rejects a `content` over 2000 characters with a 400. CloudWatch's own field
// limits add up past that on their own: AlarmName 255 + AlarmDescription 1024 +
// NewStateReason 1024 is 2303 before any formatting, and a long reason string is exactly
// what an interesting alarm produces. Unclamped, the alarm most worth reading is the one
// most likely to be rejected - and since this function deliberately has no alarm of its
// own, the retries would expire and nobody would ever hear it.
const DISCORD_CONTENT_LIMIT = 2000;

/**
 * Trim to Discord's limit from the END, so the headline (alarm name and state) always
 * survives. Losing the tail of a reason string costs detail; losing the head would cost
 * the identity of what fired.
 */
function clampForDiscord(content) {
  if (content.length <= DISCORD_CONTENT_LIMIT) return content;
  const suffix = "\n... (truncated)";
  return content.slice(0, DISCORD_CONTENT_LIMIT - suffix.length) + suffix;
}

/**
 * Turn one CloudWatch alarm payload into a line worth reading at 2am.
 *
 * Falls back to the raw message when the payload is not the alarm shape: SNS carries
 * anything published to the topic, and a message this cannot parse is still a message
 * someone meant to send. Dropping it would make this forwarder the silent link.
 */
function formatAlarm(rawMessage, subject) {
  let alarm;
  try {
    alarm = JSON.parse(rawMessage);
  } catch {
    return `:bell: **AWS notification**${subject ? ` - ${subject}` : ""}\n\`\`\`\n${rawMessage.slice(0, 1500)}\n\`\`\``;
  }
  if (!alarm || typeof alarm !== "object" || !alarm.AlarmName) {
    return `:bell: **AWS notification**${subject ? ` - ${subject}` : ""}\n\`\`\`\n${rawMessage.slice(0, 1500)}\n\`\`\``;
  }

  const state = alarm.NewStateValue;
  // OK is forwarded too, not suppressed. An alarm that announces incidents but never
  // announces recovery leaves people assuming the last thing they heard is still true.
  const icon = state === "ALARM" ? ":rotating_light:" : state === "OK" ? ":white_check_mark:" : ":grey_question:";
  const headline = state === "ALARM"
    ? `${icon} **${alarm.AlarmName}** is in ALARM`
    : state === "OK"
      ? `${icon} **${alarm.AlarmName}** recovered`
      : `${icon} **${alarm.AlarmName}** is ${state || "in an unknown state"}`;

  const parts = [headline];
  if (alarm.AlarmDescription) parts.push(alarm.AlarmDescription);
  // The reason carries the datapoint that tripped it, which is the difference between
  // "something is wrong" and knowing whether it was a real error or missing data.
  if (alarm.NewStateReason) parts.push(`\`${alarm.NewStateReason}\``);
  return parts.join("\n");
}

/**
 * THROWS when it cannot deliver, so the failure lands on this function's own Errors
 * metric instead of vanishing. There is deliberately no alarm on THAT metric: it would
 * be an alarm whose only notification path is the thing that just failed. The
 * honest position is that this forwarder is best-effort by construction, and saying so
 * beats inventing a guarantee it cannot keep.
 */
async function postToDiscord(content) {
  if (!ALARM_WEBHOOK_PARAM) {
    throw new Error(`ALARM_WEBHOOK_PARAM not set - alarm NOT delivered: ${content}`);
  }
  const result = await ssm.send(new GetParameterCommand({Name: ALARM_WEBHOOK_PARAM, WithDecryption: true}));
  const url = result.Parameter?.Value;
  // An unset SSM parameter comes back as the literal string "None".
  if (!url || url === "None") {
    throw new Error(`no webhook configured at ${ALARM_WEBHOOK_PARAM} - alarm NOT delivered: ${content}`);
  }
  // Clamped HERE rather than only in formatAlarm, so every caller is covered including
  // the raw-passthrough path for messages that are not alarms at all.
  const response = await fetch(url, {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({content: clampForDiscord(content)}),
    signal: AbortSignal.timeout(8000),
  });
  // fetch() does not reject on 401/404/429/500.
  if (!response.ok) {
    throw new Error(`webhook returned ${response.status} ${response.statusText} - alarm NOT delivered`);
  }
}

export const handler = async event => {
  const records = event?.Records ?? [];
  if (records.length === 0) {
    // An empty batch means SNS invoked this with nothing, or the event shape changed.
    // Returning quietly would make a broken integration look like a quiet night.
    throw new Error("SNS event contained no Records - nothing was forwarded");
  }

  // Every record gets its own delivery ATTEMPT, and failures are collected rather than
  // thrown at the first one: a batch of two alarms must not lose the second because
  // the first could not be delivered.
  const failures = [];
  for (const record of records) {
    const message = record?.Sns?.Message;
    if (typeof message !== "string") {
      failures.push("record had no Sns.Message string");
      continue;
    }
    try {
      await postToDiscord(formatAlarm(message, record?.Sns?.Subject));
    } catch (error) {
      failures.push(error.message);
    }
  }

  if (failures.length > 0) {
    throw new Error(`${failures.length} of ${records.length} alarm(s) NOT delivered: ${failures.join("; ")}`);
  }
  console.log(`forwarded ${records.length} alarm notification(s) to Discord`);
  return {forwarded: records.length};
};
