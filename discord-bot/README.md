# Valheim Discord bot

The Discord control plane for the Valheim server. Whitelisted friends can wake a
stopped server and inspect its state.

## Commands

- `/valheim-start` starts the server and reports when it should be ready.
- `/valheim-status` reports whether the server is running and who is online.

## Register commands

Set `DISCORD_APP_ID` and `DISCORD_BOT_TOKEN`, then run:

```sh
node register-commands.mjs
```

See `register-commands.mjs` for guild-scoped registration and SSM token lookup.

## Test

```sh
npm install --no-audit --no-fund
npm test
```
