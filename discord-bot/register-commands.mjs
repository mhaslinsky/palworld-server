// One-time (idempotent) registration of the bot's slash commands with Discord.
//
//   DISCORD_APP_ID=... DISCORD_BOT_TOKEN=... node register-commands.mjs
//
// The bot token can be pulled from SSM if you don't want it in your shell history:
//   export DISCORD_APP_ID=$(cd ../terraform && terraform output -raw discord_app_id 2>/dev/null || echo "<app-id>")
//   export DISCORD_BOT_TOKEN=$(aws ssm get-parameter --name /palworld-server/discord_bot_token \
//     --with-decryption --query Parameter.Value --output text --region us-east-1)
//
// This does a BULK OVERWRITE (PUT): the command set below becomes the exact set of
// global commands. Editing this list and re-running is how you add/remove/change a
// command — it is safe to run repeatedly. Registration authenticates with the BOT
// TOKEN (Authorization: Bot ...), NOT the interactions public key.
//
// Global commands can take up to ~1 hour to propagate the first time. For instant
// iteration during setup, register to a single guild instead (see GUILD_ID below).

const APP_ID = process.env.DISCORD_APP_ID;
const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN;
const GUILD_ID = process.env.DISCORD_GUILD_ID; // optional: instant, guild-scoped registration

if (!APP_ID || !BOT_TOKEN) {
  console.error("Set DISCORD_APP_ID and DISCORD_BOT_TOKEN (see the header of this file).");
  process.exit(1);
}

const STRING_OPTION = 3; // Discord ApplicationCommandOptionType.STRING

const commands = [
  { name: "palworld-start", description: "Start the Palworld server", type: 1 },
  { name: "palworld-status", description: "Check if the Palworld server is up and who's online", type: 1 },
  {
    name: "ask",
    description: "Ask a Palworld question (items, Pals, recipes, mechanics)",
    type: 1,
    options: [
      { name: "question", description: "Your Palworld question", type: STRING_OPTION, required: true },
    ],
  },
];

const url = GUILD_ID
  ? `https://discord.com/api/v10/applications/${APP_ID}/guilds/${GUILD_ID}/commands`
  : `https://discord.com/api/v10/applications/${APP_ID}/commands`;

const response = await fetch(url, {
  method: "PUT",
  headers: { authorization: `Bot ${BOT_TOKEN}`, "content-type": "application/json" },
  body: JSON.stringify(commands),
});

if (!response.ok) {
  console.error(`registration failed: HTTP ${response.status}`);
  console.error(await response.text());
  process.exit(1);
}

const registered = await response.json();
console.log(`Registered ${registered.length} command(s) ${GUILD_ID ? `to guild ${GUILD_ID}` : "globally"}:`);
for (const command of registered) console.log(`  /${command.name}`);
