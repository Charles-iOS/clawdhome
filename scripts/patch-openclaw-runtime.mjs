#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const packageDir = process.argv[2];
if (!packageDir) {
  console.error("usage: patch-openclaw-runtime.mjs <openclaw-package-dir>");
  process.exit(2);
}

const distDir = path.join(packageDir, "dist");
const lockFile = fs
  .readdirSync(distDir)
  .find((name) => /^gateway-lock-.+\.js$/.test(name));
const telegramPollingFile = fs
  .readdirSync(path.join(distDir, "extensions", "telegram"))
  .find((name) => /^monitor-polling\.runtime-.+\.js$/.test(name));

if (!lockFile) {
  throw new Error(`gateway lock bundle not found in ${distDir}`);
}
if (!telegramPollingFile) {
  throw new Error(`telegram polling monitor bundle not found in ${distDir}`);
}

const lockPath = path.join(distDir, lockFile);
let source = fs.readFileSync(lockPath, "utf8");
let changed = false;

const helper = `function isGatewayOwnerArgv(args) {
\tif (isGatewayArgv(args, { allowGatewayBinary: true })) return true;
\treturn args.some((arg) => {
\t\tconst normalized = String(arg).toLowerCase().replaceAll("\\\\", "/");
\t\treturn normalized === "openclaw-gateway" || normalized.endsWith("/openclaw-gateway");
\t});
}
`;

if (!source.includes("function isGatewayOwnerArgv(args)")) {
  source = source.replace("function readLinuxStartTime(pid) {", `${helper}function readLinuxStartTime(pid) {`);
  changed = true;
}

const eagerPortDeadCheck = `async function resolveGatewayOwnerStatus(pid, payload, platform, port, readCmdline) {
\tif (port != null) {
\t\tif (await checkPortFree(port)) return "dead";
\t}
\tif (!isPidAlive(pid)) return "dead";`;
const pidFirstOwnerCheck = `async function resolveGatewayOwnerStatus(pid, payload, platform, port, readCmdline) {
\tif (!isPidAlive(pid)) return "dead";`;

if (source.includes(eagerPortDeadCheck)) {
  source = source.replace(eagerPortDeadCheck, pidFirstOwnerCheck);
  changed = true;
} else if (!source.includes(pidFirstOwnerCheck)) {
  throw new Error("gateway lock owner status function shape changed before pid check");
}

const oldOwnerReturn = `\treturn isGatewayArgv(args) ? "alive" : "dead";`;
const safeOwnerReturn = `\tif (!isGatewayOwnerArgv(args)) return "dead";
\tif (port != null && await checkPortFree(port)) return "unknown";
\treturn "alive";`;

if (source.includes(oldOwnerReturn)) {
  source = source.replace(oldOwnerReturn, safeOwnerReturn);
  changed = true;
} else if (!source.includes(safeOwnerReturn)) {
  throw new Error("gateway lock owner status function shape changed before argv check");
}

if (changed) {
  fs.writeFileSync(lockPath, source);
  console.log(`patched ${lockPath}`);
} else {
  console.log(`already patched ${lockPath}`);
}

const telegramPollingPath = path.join(distDir, "extensions", "telegram", telegramPollingFile);
source = fs.readFileSync(telegramPollingPath, "utf8");
changed = false;

const runnerOnlyStallCheck = "if (elapsed > POLL_STALL_THRESHOLD_MS && apiElapsed > POLL_STALL_THRESHOLD_MS && runner.isRunning()) {";
const runnerAgnosticStallCheck = "if (elapsed > POLL_STALL_THRESHOLD_MS && apiElapsed > POLL_STALL_THRESHOLD_MS) {";
if (source.includes(runnerOnlyStallCheck)) {
  source = source.replace(runnerOnlyStallCheck, runnerAgnosticStallCheck);
  changed = true;
} else if (!source.includes(runnerAgnosticStallCheck)) {
  throw new Error("telegram polling watchdog condition shape changed");
}

const oldStallDiag = "offset=${lastGetUpdatesOffset ?? \"n/a\"}${lastGetUpdatesError ? ` error=${lastGetUpdatesError}` : \"\"}]`);";
const newStallDiag = "offset=${lastGetUpdatesOffset ?? \"n/a\"} runnerRunning=${runner.isRunning()}${lastGetUpdatesError ? ` error=${lastGetUpdatesError}` : \"\"}]`);";
if (source.includes(oldStallDiag)) {
  source = source.replace(oldStallDiag, newStallDiag);
  changed = true;
} else if (!source.includes("runnerRunning=${runner.isRunning()}")) {
  throw new Error("telegram polling watchdog diagnostic shape changed");
}

if (changed) {
  fs.writeFileSync(telegramPollingPath, source);
  console.log(`patched ${telegramPollingPath}`);
} else {
  console.log(`already patched ${telegramPollingPath}`);
}
