// Minimal client for Palworld Save Pal's WebSocket API (psp-server, port 5174).
//
// Used to compensate 7 players for the ~4.5h lost on 2026-07-18. All domain edits
// in Save Pal are WebSocket-only - the /api/convert endpoints work on raw uesave
// JSON, not the friendly Player/Pal/Item shapes - and the GUI cannot edit more
// than one player at a time, so scripting is the only way to do a whole roster.
//
// Wire format is {"type": <string>, "data": <any>} in both directions.
// Node 22 has a native WebSocket, so this needs no dependencies.

const URL_BASE = process.env.PSP_URL || "ws://127.0.0.1:5174/ws/compensation";

export class Psp {
  constructor(verbose = false) {
    this.verbose = verbose;
    this.socket = null;
    this.handlers = new Map();   // type -> [waiter,...]
    // Messages that arrived with nobody waiting. The server pushes several
    // unprompted after a load (get_player_summaries, get_guild_summaries), so a
    // client that only listens forward-in-time waits forever for something it has
    // already been sent.
    this.backlog = new Map();    // type -> [data,...]
    this.seen = [];              // every inbound message, for debugging
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.socket = new WebSocket(URL_BASE);
      this.socket.addEventListener("open", () => resolve());
      this.socket.addEventListener("error", (event) => reject(new Error(`ws error: ${event.message ?? "unknown"}`)));
      this.socket.addEventListener("close", () => {
        // A close mid-flight would otherwise hang every pending waiter forever.
        for (const [, waiters] of this.handlers) {
          for (const waiter of waiters) waiter.reject(new Error("socket closed while waiting"));
        }
        this.handlers.clear();
      });
      this.socket.addEventListener("message", (event) => {
        let payload;
        try {
          payload = JSON.parse(event.data);
        } catch {
          return;
        }
        this.seen.push(payload);
        if (this.verbose) console.error(`<- ${payload.type}`);
        const waiters = this.handlers.get(payload.type);
        if (waiters?.length) {
          waiters.shift().resolve(payload.data ?? payload);
        } else {
          if (!this.backlog.has(payload.type)) this.backlog.set(payload.type, []);
          this.backlog.get(payload.type).push(payload.data ?? payload);
        }
      });
    });
  }

  send(type, data) {
    if (this.verbose) console.error(`-> ${type}`);
    this.socket.send(JSON.stringify(data === undefined ? {type} : {type, data}));
  }

  /**
   * Wait for one of `types`. Rejects on timeout AND on the server's error
   * messages - the server reports business errors as their own message type, so
   * without listening for those a failed call just looks like a hang.
   */
  wait(types, timeoutMs = 120000) {
    const wanted = Array.isArray(types) ? types : [types];
    const errorTypes = ["error", "business_error", "warning"];

    // Already delivered? Take it from the backlog rather than waiting for a
    // second copy that will never come.
    for (const type of wanted) {
      const queued = this.backlog.get(type);
      if (queued?.length) return Promise.resolve(queued.shift());
    }

    return new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`timeout waiting for ${wanted.join("|")} (saw: ${this.seen.slice(-6).map((m) => m.type).join(", ")})`)),
        timeoutMs,
      );
      const settle = (fn) => (value) => { clearTimeout(timer); fn(value); };
      for (const type of [...wanted, ...errorTypes]) {
        const waiter = errorTypes.includes(type) && !wanted.includes(type)
          ? {resolve: settle((data) => reject(new Error(`server ${type}: ${JSON.stringify(data)}`))), reject: settle(reject)}
          : {resolve: settle(resolve), reject: settle(reject)};
        if (!this.handlers.has(type)) this.handlers.set(type, []);
        this.handlers.get(type).push(waiter);
      }
    });
  }

  async call(type, data, expect, timeoutMs) {
    const pending = this.wait(expect, timeoutMs);
    this.send(type, data);
    return pending;
  }

  close() {
    this.socket?.close();
  }
}

export async function connect(verbose = false) {
  const client = new Psp(verbose);
  await client.connect();
  return client;
}
