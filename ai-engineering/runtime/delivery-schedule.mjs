// Install one user-owned launchd job for a bound delivery; never run from SessionStart.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
const [file, repo, script, mode] = process.argv.slice(2);
const b = mode === "remove" && !fs.existsSync(file)
  ? { repo_identity: path.basename(path.dirname(file)) }
  : JSON.parse(fs.readFileSync(file, "utf8"));
if (!/^[a-f0-9]{64}$/.test(b.repo_identity))
  throw Error("Invalid repository identity");
const label = `com.arkira.delivery.${b.repo_identity}`;
const target = path.join(
  os.homedir(),
  "Library",
  "LaunchAgents",
  `${label}.plist`,
);
const xml = (value) =>
  String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
if (mode === "remove") {
  if (fs.existsSync(target) && !fs.lstatSync(target).isSymbolicLink())
    fs.unlinkSync(target);
  try {
    execFileSync("launchctl", ["bootout", `gui/${process.getuid()}/${label}`], {
      stdio: "ignore",
    });
  } catch {}
} else {
  const args = ["/bin/bash", script, repo, "_scheduled"];
  const document = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array>${args.map((a) => `<string>${xml(a)}</string>`).join("")}</array><key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(process.env.PATH)}</string><key>ARKIRA_RUNTIME_HOME</key><string>${xml(path.dirname(path.dirname(path.dirname(file))))}</string></dict><key>StartInterval</key><integer>30</integer><key>RunAtLoad</key><true/></dict></plist>\n`;
  if (mode === "print") {
    process.stdout.write(document);
    process.exit(0);
  }
  fs.mkdirSync(path.dirname(target), { recursive: true });
  if (fs.existsSync(target) && fs.lstatSync(target).isSymbolicLink())
    throw Error("Scheduler target must not be a symlink");
  fs.writeFileSync(target, document, { mode: 0o600 });
  execFileSync("plutil", ["-lint", target], { stdio: "inherit" });
  try {
    execFileSync("launchctl", ["bootout", `gui/${process.getuid()}/${label}`], {
      stdio: "ignore",
    });
  } catch {}
  execFileSync("launchctl", ["bootstrap", `gui/${process.getuid()}`, target], {
    stdio: "inherit",
  });
  console.log(
    `Scheduled bounded recovery: ${label}. Active delivery uses ${script}.`,
  );
}
