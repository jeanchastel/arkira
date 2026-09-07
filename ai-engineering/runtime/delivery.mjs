// A release binding and recovery journal; native goals remain the completion authority.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { codexClient, codexReadClient } from "./native-codex.mjs";
import { readClaudeGoal } from "./native-claude.mjs";

const now = () => Math.floor(Date.now() / 1000);
const sha = (value) =>
  typeof value === "string" && /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value);
const run = (command, args, cwd) =>
  execFileSync(command, args, {
    cwd,
    encoding: "utf8",
    timeout: 30000,
    maxBuffer: 4 * 1024 * 1024,
  });
const json = (command, args, cwd) => JSON.parse(run(command, args, cwd));
const read = (filename) => {
  if (
    !fs.lstatSync(filename).isFile() ||
    fs.lstatSync(filename).isSymbolicLink()
  )
    throw Error("State must be a regular file");
  return JSON.parse(fs.readFileSync(filename, "utf8"));
};
function write(filename, value) {
  const temp = `${filename}.${process.pid}.tmp`;
  const fd = fs.openSync(temp, "wx", 0o600);
  try {
    fs.writeFileSync(fd, JSON.stringify(value) + "\n");
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temp, filename);
  const directory = fs.openSync(path.dirname(filename), "r");
  try {
    fs.fsyncSync(directory);
  } finally {
    fs.closeSync(directory);
  }
}

export function nextAttempt(binding, time) {
  const failures = (binding.failures || 0) + 1;
  return {
    failures,
    state: failures >= 6 ? "blocked" : "waiting",
    next_poll_epoch: time + Math.min(30 * 2 ** (failures - 1), 900),
  };
}
export async function observeDelivery(binding, readPR, readDeployments, readDeployRun) {
  const pr = await readPR(binding);
  if (
    pr.number !== binding.pr ||
    pr.base?.repo?.full_name !== binding.repo ||
    pr.head?.sha !== binding.head
  )
    return {
      state: "blocked",
      stage: "merge",
      reason: "PR identity or head changed; bind the newly validated candidate",
    };
  if (!pr.merged && pr.state === "closed")
    return {
      state: "blocked",
      stage: "merge",
      reason: "PR closed without merge",
    };
  if (binding.target !== "preview" && !pr.merged) {
    return { state: "waiting", stage: "merge", revision: binding.head };
  }
  const revision =
    binding.target === "preview" ? binding.head : pr.merge_commit_sha;
  if (!sha(revision)) throw Error("Provider did not return a valid revision");
  if (binding.target === "merged")
    return { state: "ready", stage: "merge", revision };
  const deployments = (await readDeployments(binding, revision))
    .filter(
      (d) =>
        d.meta?.githubCommitSha === revision &&
        d.projectId === binding.project &&
        (binding.target === "production"
          ? d.target === "production"
          : d.target === null || d.target === "preview"),
    )
    .sort(
      (a, b) =>
        (b.createdAt || b.created || 0) - (a.createdAt || a.created || 0),
    );
  const deployment = deployments[0];
  if (!deployment) {
    if (binding.deployment_workflow && readDeployRun) {
      const run = await readDeployRun(binding, revision);
      if (run?.conclusion && run.conclusion !== "success")
        return { state: "blocked", stage: "deployment", revision,
          reason: `Deployment workflow ${run.conclusion}: ${run.html_url || run.id}` };
    }
    return { state: "waiting", stage: "deployment", revision };
  }
  const evidence = {
    revision,
    deployment_id: deployment.id || deployment.uid,
    url: deployment.url,
    environment: binding.target,
    readiness_scope: "immutable_deployment",
  };
  if (
    (deployment.readyState || deployment.state) === "READY" &&
    (typeof evidence.deployment_id !== "string" ||
      !evidence.deployment_id.trim() ||
      typeof evidence.url !== "string" ||
      !evidence.url.trim())
  )
    throw Error("Ready deployment requires an exact deployment ID and URL");
  if (["ERROR", "CANCELED"].includes(deployment.readyState || deployment.state))
    return {
      ...evidence,
      state: "blocked",
      stage: "deployment",
      reason: `Deployment ${deployment.readyState || deployment.state}`,
    };
  return {
    ...evidence,
    state:
      (deployment.readyState || deployment.state) === "READY"
        ? "ready"
        : "waiting",
    stage: "deployment",
  };
}
function providers(cwd) {
  return {
    readPR: (b) => json("gh", ["api", `repos/${b.repo}/pulls/${b.pr}`], cwd),
    readDeployRun: (b, revision) => {
      const result = json("gh", ["api", `repos/${b.repo}/actions/workflows/${b.deployment_workflow}/runs?head_sha=${revision}&event=push&per_page=20`], cwd);
      return (result.workflow_runs || []).filter((r) => r.head_sha === revision)
        .sort((a, z) => z.id - a.id)[0];
    },
    readDeployments: (b, revision) => {
      const query = new URLSearchParams({
        projectId: b.project,
        teamId: b.team,
        "meta-githubCommitSha": revision,
        target: b.target,
        limit: "20",
      });
      const list = json(
        "vercel",
        ["api", `/v6/deployments?${query}`, "--method", "GET", "--raw"],
        cwd,
      );
      // v6 list entries may omit projectId; the request itself is project-scoped.
      return (list.deployments || []).map((d) => ({
        ...d,
        projectId: d.projectId || b.project,
      }));
    },
  };
}
export function validateBinding(b, goal) {
  if (
    b.schema_version !== 1 ||
    typeof b.goal_id !== "string" ||
    !b.goal_id ||
    !/^[a-f0-9]{64}$/.test(b.repo_identity) ||
    !sha(b.harness?.content_digest) ||
    !sha(b.head) ||
    !sha(b.candidate_tree) ||
    !["merged", "preview", "production"].includes(b.target) ||
    !/^[\w.-]+\/[\w.-]+$/.test(b.repo) ||
    !Number.isSafeInteger(b.pr) ||
    b.pr < 1 ||
    !/^[a-zA-Z0-9-]+$/.test(b.session) ||
    !["codex", "claude"].includes(b.provider) ||
    !path.isAbsolute(b.cwd)
  )
    throw Error("Invalid or stale delivery binding");
  if (
    goal &&
    (goal.state !== "sealed" ||
      b.goal_id !== goal.goal_id ||
      b.repo_identity !== goal.repo_identity ||
      b.harness.content_digest !== goal.harness?.content_digest ||
      b.candidate_tree !== goal.worktree_tree)
  )
    throw Error("Delivery must bind the sealed candidate tree");
  if (
    b.target !== "merged" &&
    (!/^prj_[\w]+$/.test(b.project) || !/^team_[\w]+$/.test(b.team))
  )
    throw Error("Deployment target requires exact Vercel project and team");
  if (
    b.native_socket !== undefined &&
    (b.provider !== "codex" ||
      typeof b.native_socket !== "string" ||
      !path.isAbsolute(b.native_socket))
  )
    throw Error("Native socket must identify an existing Codex owner");
}
export const sameNativeGoal = (binding, goal) =>
  Boolean(
    binding.native_goal &&
    goal &&
    goal.createdAt === binding.native_goal.createdAt &&
    goal.objective === binding.native_goal.objective,
  );
async function readNativeOwner(client, b, requireLoaded = true) {
  const { thread } = await client.request("thread/read", {
    threadId: b.session,
    includeTurns: false,
  });
  if (requireLoaded && !["active", "idle"].includes(thread.status?.type))
    throw Error(
      "Bound session is not loaded in the supplied native owner; resume it there first",
    );
  if (fs.realpathSync(thread.cwd) !== fs.realpathSync(b.cwd))
    throw Error("Native session belongs to another worktree");
  return (await client.request("thread/goal/get", { threadId: b.session }))
    .goal;
}
async function bind(filename, goal, cwd, options) {
  if (fs.existsSync(filename))
    throw Error(
      "Delivery already bound; cancel it explicitly before replacing",
    );
  const b = {
    schema_version: 1,
    goal_id: goal.goal_id,
    repo_identity: goal.repo_identity,
    harness: goal.harness,
    cwd,
    repo: options.repo,
    pr: Number(options.pr),
    head: options.head,
    target: options.target,
    provider: options.provider,
    session: options.session,
    native_transcript: options["native-transcript"],
    project: options.project,
    team: options.team,
    native_socket: options["native-socket"],
    state: "waiting",
    stage: "merge",
    created_epoch: now(),
    updated_epoch: now(),
    deadline_epoch: now() + 86400,
    next_poll_epoch: 0,
    failures: 0,
  };
  if (
    run("git", ["rev-parse", "HEAD"], cwd).trim() !== b.head ||
    run("git", ["status", "--porcelain"], cwd).trim()
  )
    throw Error("Bind only the committed, clean validated head");
  b.candidate_tree = run("git", ["rev-parse", "HEAD^{tree}"], cwd).trim();
  if (b.target === "production" && run("git", ["ls-tree", "--name-only", b.head, "scripts/deploy-production.sh"], cwd).trim())
    b.deployment_workflow = "arkira-post-merge.yml";
  validateBinding(b, goal);
  if (b.provider === "codex") {
    if (b.native_socket) {
      const socket = fs.lstatSync(b.native_socket);
      if (!socket.isSocket() || socket.uid !== process.getuid())
        throw Error("Native owner socket must be a user-owned Unix socket");
    }
    const client = b.native_socket
      ? await codexClient(b.native_socket)
      : await codexReadClient();
    try {
      const native = await readNativeOwner(client, b, Boolean(b.native_socket));
      if (!native || native.status !== "active")
        throw Error("Native goal must actually be active before binding");
      b.native_goal = {
        createdAt: native.createdAt,
        objective: native.objective,
      };
    } finally {
      client.close();
    }
  }
  if (b.provider === "claude") {
    if (!b.native_transcript)
      throw Error(
        "Claude binding requires --native-transcript for native goal evidence",
      );
    const native = await readClaudeGoal(b.native_transcript, b.session, cwd);
    if (!native || native.status !== "active")
      throw Error("Native Claude goal must actually be active before binding");
    b.native_goal = {
      createdAt: native.createdAt,
      objective: native.objective,
    };
  }
  // Without a shared native owner this binding only observes release evidence.
  const { readPR } = providers(cwd);
  const pr = readPR(b);
  if (pr.head?.sha !== b.head || pr.base?.repo?.full_name !== b.repo)
    throw Error("PR does not match the bound repository and revision");
  write(filename, b);
  return b;
}
export async function nativeResume(filename, b, connect = codexClient) {
  const productionCheck =
    b.target === "production"
      ? " Deployment readiness covers the immutable deployment only. Verify the current production alias points to the requested deployment and revision before accepting the production Definition of Done."
      : "";
  const prompt = `Arkira delivery evidence for goal ${b.goal_id}: ${JSON.stringify(b.evidence)}. Read current authoritative state for ${b.repo} PR ${b.pr}, requested target ${b.target}. Verify only the remaining acceptance criteria at the exact revision/environment.${productionCheck} Consume applicable existing validation; do not rerun full CI, merge, deploy, or make code changes. Complete the native goal only if its Definition of Done is satisfied; otherwise report the specific blocker. Delivery token: ${b.goal_id}:${b.head}:${b.target}.`;
  if (b.provider !== "codex" || !b.native_socket) {
    b.state = "verification";
    b.native_result = { dispatch: "owner-required" };
    b.reason =
      "Delivery evidence is ready. Complete remaining verification in the bound native session; no shared native owner was supplied.";
    write(filename, b);
    return b;
  }
  const client = await connect(b.native_socket);
  try {
    const goal = await readNativeOwner(client, b);
    if (!sameNativeGoal(b, goal))
      throw Error("Native goal changed or was cleared; recovery stopped");
    if (goal.status === "complete") {
      b.state = "completed";
      b.native_result = goal;
      write(filename, b);
      return b;
    }
    // Never override pause, budget, usage, cancellation, or a user-action blocker.
    if (goal.status !== "active")
      throw Error(
        `Native goal is ${goal.status}; explicitly resume it before recovery`,
      );
    // Rejoin only the already loaded thread on this owner. Native turn/start may
    // steer its active turn; supplying this socket opts into that native behavior.
    const resumed = await client.request("thread/resume", {
      threadId: b.session,
      excludeTurns: true,
    });
    b.native_result = { model: resumed.model, effort: resumed.reasoningEffort };
    const current = await readNativeOwner(client, b);
    if (!sameNativeGoal(b, current) || current.status !== "active")
      throw Error("Native goal changed or stopped before delivery input");
    const { turn } = await client.request("turn/start", {
      threadId: b.session,
      input: [{ type: "text", text: prompt }],
      clientUserMessageId: `arkira-${b.goal_id}-${b.head}-${b.target}`,
    });
    b.native_turn_id = turn.id;
    write(filename, b);
    const result = await client.waitForTurn(b.session, turn.id);
    const { goal: after } = await client.request("thread/goal/get", {
      threadId: b.session,
    });
    if (!sameNativeGoal(b, after))
      throw Error("Native goal changed during delivery verification");
    b.state = after?.status === "complete" ? "completed" : "verification";
    b.native_result = {
      ...b.native_result,
      turn_status: result.status,
      goal: after,
    };
    if (result.status !== "completed") {
      b.state = "blocked";
      b.reason = "Native verification turn failed or was interrupted";
    }
    write(filename, b);
    return b;
  } finally {
    client.close();
  }
}
export async function recover(
  filename,
  b,
  { connect = codexClient, readConnect = codexReadClient } = {},
) {
  if (["completed", "blocked", "cancelled"].includes(b.state)) return b;
  if (now() > b.deadline_epoch) {
    b.state = "blocked";
    b.reason = "Delivery recovery expired after 24 hours";
    write(filename, b);
    return b;
  }
  if (b.state === "resuming") {
    // Journal precedes dispatch. A crash in the acknowledgement window must not duplicate a turn.
    b.state = "blocked";
    b.reason =
      "Interrupted native dispatch; inspect native session and managed job before explicit recovery";
    write(filename, b);
    return b;
  }
  if (now() < b.next_poll_epoch) return b;
  if (b.state === "verification") {
    if (b.provider === "claude") {
      try {
        const goal = await readClaudeGoal(
          b.native_transcript,
          b.session,
          b.cwd,
        );
        if (!sameNativeGoal(b, goal)) {
          b.state = "blocked";
          b.reason = "Native Claude goal changed or was cleared";
        } else if (goal.status === "complete") {
          b.state = "completed";
          b.native_result = { goal };
          delete b.reason;
        }
        if (sameNativeGoal(b, goal) && !["active", "complete"].includes(goal.status)) {
          b.state = "blocked";
          b.reason = `Native goal is ${goal.status}; resume it in its owner before recovery`;
        }
        b.failures = 0;
        b.next_poll_epoch = now() + 30;
      } catch (cause) {
        const retry = nextAttempt(b, now());
        Object.assign(b, retry, {
          state: retry.state === "blocked" ? "blocked" : "verification",
          reason: cause.message,
        });
      }
      b.updated_epoch = now();
      write(filename, b);
    }

    if (b.provider === "codex") {
      let client;
      try {
        client = b.native_socket
          ? await connect(b.native_socket)
          : await readConnect();
        const { goal } = await client.request("thread/goal/get", {
          threadId: b.session,
        });
        if (!sameNativeGoal(b, goal)) {
          b.state = "blocked";
          b.reason = "Native goal changed during verification";
        }
        if (sameNativeGoal(b, goal) && goal.status === "complete") {
          b.state = "completed";
          b.native_result = { ...b.native_result, goal };
          delete b.reason;
        }
        if (sameNativeGoal(b, goal) && !["active", "complete"].includes(goal.status)) {
          b.state = "blocked";
          b.reason = `Native goal is ${goal.status}; resume it in its owner before recovery`;
        }
        b.failures = 0;
        b.next_poll_epoch = now() + 30;
      } catch (cause) {
        const retry = nextAttempt(b, now());
        Object.assign(b, retry, {
          state: retry.state === "blocked" ? "blocked" : "verification",
          reason: cause.message,
        });
      } finally {
        client?.close();
      }
      b.updated_epoch = now();
      write(filename, b);
    }
    return b;
  }
  try {
    const { readPR, readDeployments, readDeployRun } = providers(b.cwd);
    b.evidence = await observeDelivery(b, readPR, readDeployments, readDeployRun);
    b.stage = b.evidence.stage;
    b.state = b.evidence.state;
    b.reason = b.evidence.reason;
    b.updated_epoch = now();
    b.failures = 0;
    b.next_poll_epoch = now() + 30;
    if (b.state === "ready") {
      b.state = "resuming";
      write(filename, b);
      return await nativeResume(filename, b);
    }
  } catch (cause) {
    if (b.state === "resuming") {
      b.state = "blocked";
      b.reason = cause.message;
    } else {
      Object.assign(b, nextAttempt(b, now()));
      b.reason = cause.message;
    }
  }
  write(filename, b);
  return b;
}

export async function main(args) {
  const [command, filename, cwd, ...rest] = args;
  if (!["bind", "status", "recover", "cancel"].includes(command))
    throw Error("Unknown delivery command");
  // Caller holds the existing job-control ownership lock for every mutation.
  if (command === "status") {
    const b = read(filename);
    validateBinding(b);
    return { ...b, stale: now() - b.updated_epoch > 120 };
  }
  const goal = read(path.join(path.dirname(filename), "active.json"));
  if (command === "bind") {
    const options = {};
    for (let i = 0; i < rest.length; i += 2) {
      if (!rest[i]?.startsWith("--") || !rest[i + 1])
        throw Error("Expected --name value");
      options[rest[i].slice(2)] = rest[i + 1];
    }
    return bind(filename, goal, cwd, options);
  }
  const b = read(filename);
  validateBinding(b, goal);
  if (command === "cancel") {
    b.state = "cancelled";
    b.updated_epoch = now();
    write(filename, b);
    return b;
  }

  return recover(filename, b);
}
if (
  process.argv[1] &&
  fileURLToPath(import.meta.url) === path.resolve(process.argv[1])
) {
  main(process.argv.slice(2))
    .then((result) => console.log(JSON.stringify(result)))
    .catch((cause) => {
      console.error(`delivery: ${cause.message}`);
      process.exitCode = 1;
    });
}
