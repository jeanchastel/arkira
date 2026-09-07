// Native continuation uses an existing owner; isolated discovery permits reads only.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import path from "node:path";

export async function codexClient(socket, options = {}) {
  if (typeof socket !== "string" || !path.isAbsolute(socket))
    throw Error("An explicit native owner socket is required");
  return nativeTransport(["app-server", "proxy", "--sock", socket], options);
}
export async function codexReadClient(options = {}) {
  const { request, close } = await nativeTransport(
    ["app-server", "--stdio"],
    options,
    new Set(["initialize", "model/list", "thread/read", "thread/goal/get"]),
  );
  return { request, close };
}
async function nativeTransport(
  args,
  {
    spawnProcess = spawn,
    requestTimeoutMs = 30000,
    turnTimeoutMs = 300000,
  } = {},
  allowedMethods,
) {
  const child = spawnProcess("codex", args, {
    stdio: ["pipe", "pipe", "pipe"],
  });
  const pending = new Map();
  const waiting = new Map(),
    completed = new Map();
  let id = 0,
    error = "",
    closed;
  child.stderr.on("data", (chunk) => {
    error = (error + chunk).slice(-2000);
  });
  const fail = (cause) => {
    closed ||= cause;
    for (const map of [pending, waiting]) {
      for (const p of map.values()) p.reject(cause);
      map.clear();
    }
  };
  child.on("error", fail);
  child.stdin.on("error", fail);
  child.on("exit", () =>
    fail(new Error(`Native owner connection exited: ${error}`)),
  );
  createInterface({ input: child.stdout })
    .on("close", () => fail(Error("Native owner connection closed")))
    .on("line", (line) => {
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return;
      }
      if (message.id != null && !message.method && pending.has(message.id)) {
        const p = pending.get(message.id);
        pending.delete(message.id);
        if (message.error) p.reject(new Error(message.error.message));
        else p.resolve(message.result);
      } else if (message.id != null && message.method) {
        // Background recovery cannot approve new permissions or impersonate the operator.
        child.stdin.write(
          JSON.stringify({
            id: message.id,
            error: {
              code: -32601,
              message: "Operator input required; resume interactively",
            },
          }) + "\n",
        );
      } else if (
        message.method === "turn/completed" &&
        message.params?.threadId &&
        message.params?.turn?.id
      ) {
        const key = `${message.params.threadId}:${message.params.turn.id}`;
        const waiter = waiting.get(key);
        if (waiter) {
          waiting.delete(key);
          waiter.resolve(message.params.turn);
        } else {
          completed.set(key, message.params.turn);
          if (completed.size > 32)
            completed.delete(completed.keys().next().value);
        }
      }
    });
  const request = (method, params) =>
    new Promise((resolve, reject) => {
      if (allowedMethods && !allowedMethods.has(method)) {
        reject(Error(`Read-only native client rejects ${method}`));
        return;
      }
      if (closed) {
        reject(closed);
        return;
      }
      const requestId = ++id;
      const timer = setTimeout(() => {
        pending.delete(requestId);
        reject(new Error(`Native request timed out: ${method}`));
      }, requestTimeoutMs);
      pending.set(requestId, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (cause) => {
          clearTimeout(timer);
          reject(cause);
        },
      });
      child.stdin.write(
        JSON.stringify({ id: requestId, method, params }) + "\n",
      );
    });
  const waitForTurn = (threadId, turnId) =>
    new Promise((resolve, reject) => {
      const key = `${threadId}:${turnId}`;
      if (completed.has(key)) {
        const turn = completed.get(key);
        completed.delete(key);
        resolve(turn);
        return;
      }
      if (closed) {
        reject(closed);
        return;
      }
      if (waiting.has(key)) {
        reject(Error("Turn already has a completion waiter"));
        return;
      }
      const timer = setTimeout(() => {
        waiting.delete(key);
        reject(Error(`Native turn timed out: ${turnId}`));
      }, turnTimeoutMs);
      waiting.set(key, {
        resolve: (turn) => {
          clearTimeout(timer);
          resolve(turn);
        },
        reject: (cause) => {
          clearTimeout(timer);
          reject(cause);
        },
      });
    });
  // A proxy disconnect leaves its owner's turn running; discovery has no turns.
  const close = () => {
    fail(Error("Native owner connection closed"));
    child.stdin.end();
    child.kill("SIGTERM");
  };
  try {
    await request("initialize", {
      clientInfo: { name: "arkira", version: "1.0.0" },
    });
    child.stdin.write(JSON.stringify({ method: "initialized" }) + "\n");
  } catch (cause) {
    close();
    throw cause;
  }
  return { request, close, waitForTurn };
}
