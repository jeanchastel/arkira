// Read native goal records; never rewrite a Claude session or start a second owner.
// Observed on Claude Code 2.1.241. Unknown record shapes fail closed.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createInterface } from "node:readline";
export async function readClaudeGoal(filename, session, cwd) {
  const root = fs.realpathSync(
    path.join(
      process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude"),
      "projects",
    ),
  );
  const resolved = fs.realpathSync(filename);
  if (
    !resolved.startsWith(root + path.sep) ||
    path.basename(resolved) !== `${session}.jsonl` ||
    fs.lstatSync(filename).isSymbolicLink() ||
    !fs.lstatSync(filename).isFile()
  )
    throw Error("Expected the bound native Claude transcript");
  let goal;
  const lines = createInterface({
    input: fs.createReadStream(filename),
    crlfDelay: Infinity,
  });
  try {
    for await (const line of lines) {
      let item;
      try {
        item = JSON.parse(line);
      } catch {
        continue;
      } // An interrupted final line supplies no evidence.
      if (
        item.sessionId !== session ||
        !item.cwd ||
        fs.realpathSync(item.cwd) !== fs.realpathSync(cwd)
      )
        continue;
      if (item.type === "system" && item.subtype === "local_command") {
        const match = item.content?.match(
          /^<local-command-stdout>Goal set: ([\s\S]*)<\/local-command-stdout>$/,
        );
        if (match)
          goal = {
            createdAt: item.uuid,
            objective: match[1],
            status: "active",
          };
        else if (
          /^<local-command-stdout>(Goal cleared:|No goal set)/.test(
            item.content || "",
          )
        )
          goal = undefined;
      }
      if (
        goal &&
        item.type === "attachment" &&
        item.attachment?.type === "goal_status" &&
        item.attachment.condition === goal.objective
      ) {
        if (item.attachment.met === true)
          goal = { ...goal, status: "complete", evidence: item.uuid };
        else if (item.attachment.met === false)
          goal = { ...goal, status: "active", evidence: item.uuid };
      }
    }
  } finally {
    lines.close();
  }
  return goal;
}
