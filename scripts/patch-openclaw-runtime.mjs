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

const serverImplFiles = fs
  .readdirSync(distDir)
  .filter((name) => /^server\.impl-.+\.js$/.test(name));

if (serverImplFiles.length === 0) {
  throw new Error(`server impl bundle not found in ${distDir}`);
}

for (const serverImplFile of serverImplFiles) {
  const serverImplPath = path.join(distDir, serverImplFile);
  source = fs.readFileSync(serverImplPath, "utf8");
  changed = false;

  const oldStartupGate = `\t\tparams.log.info("starting channels and sidecars...");
\t\t({pluginServices} = await runtimeDeps.startGatewaySidecars({`;
  const newStartupGate = `\t\tparams.log.info("starting channels and sidecars...");
\t\tfor (const method of STARTUP_UNAVAILABLE_GATEWAY_METHODS) params.unavailableGatewayMethods.delete(method);
\t\t({pluginServices} = await runtimeDeps.startGatewaySidecars({`;

  if (source.includes(oldStartupGate)) {
    source = source.replace(oldStartupGate, newStartupGate);
    changed = true;
  } else if (!source.includes(newStartupGate)) {
    throw new Error(`startup gate shape changed in ${serverImplPath}`);
  }

  const oldPrewarm = `\t\tawait prewarmConfiguredPrimaryModel({
\t\t\tcfg: params.cfg,
\t\t\tlog: params.log
\t\t});`;
  const newPrewarm = `\t\tif (isTruthyEnvValue(process.env.OPENCLAW_SKIP_STARTUP_PREWARM)) params.log.info("skipping startup model warmup (OPENCLAW_SKIP_STARTUP_PREWARM=1)");
\t\telse await prewarmConfiguredPrimaryModel({
\t\t\tcfg: params.cfg,
\t\t\tlog: params.log
\t\t});`;

  if (source.includes(oldPrewarm)) {
    source = source.replace(oldPrewarm, newPrewarm);
    changed = true;
  } else if (!source.includes("OPENCLAW_SKIP_STARTUP_PREWARM")) {
    throw new Error(`startup prewarm shape changed in ${serverImplPath}`);
  }

  const oldPluginBootstrapStart = `async function prepareGatewayPluginBootstrap(params) {
\tconst startupMaintenanceConfig = params.cfgAtStart.channels === void 0 && params.startupRuntimeConfig.channels !== void 0 ? {
\t\t...params.cfgAtStart,
\t\tchannels: params.startupRuntimeConfig.channels
\t} : params.cfgAtStart;
\tif (!params.minimalTestGateway) {
\t\tawait runChannelPluginStartupMaintenance({
\t\t\tcfg: startupMaintenanceConfig,
\t\t\tenv: process.env,
\t\t\tlog: params.log
\t\t});
\t\tawait runStartupSessionMigration({
\t\t\tcfg: params.cfgAtStart,
\t\t\tenv: process.env,
\t\t\tlog: params.log
\t\t});
\t}
\tinitSubagentRegistry();
\tconst gatewayPluginConfigAtStart = params.minimalTestGateway ? params.cfgAtStart : applyPluginAutoEnable({`;
  const newPluginBootstrapStart = `async function prepareGatewayPluginBootstrap(params) {
\tconst startupPluginsDisabled = isTruthyEnvValue(process.env.OPENCLAW_SKIP_STARTUP_PLUGINS) || params.cfgAtStart.plugins?.enabled === false;
\tconst startupMaintenanceConfig = params.cfgAtStart.channels === void 0 && params.startupRuntimeConfig.channels !== void 0 ? {
\t\t...params.cfgAtStart,
\t\tchannels: params.startupRuntimeConfig.channels
\t} : params.cfgAtStart;
\tif (!params.minimalTestGateway && !startupPluginsDisabled) {
\t\tawait runChannelPluginStartupMaintenance({
\t\t\tcfg: startupMaintenanceConfig,
\t\t\tenv: process.env,
\t\t\tlog: params.log
\t\t});
\t\tawait runStartupSessionMigration({
\t\t\tcfg: params.cfgAtStart,
\t\t\tenv: process.env,
\t\t\tlog: params.log
\t\t});
\t} else if (!params.minimalTestGateway) await runStartupSessionMigration({
\t\tcfg: params.cfgAtStart,
\t\tenv: process.env,
\t\tlog: params.log
\t});
\tinitSubagentRegistry();
\tconst gatewayPluginConfigAtStart = params.minimalTestGateway || startupPluginsDisabled ? params.cfgAtStart : applyPluginAutoEnable({`;

  if (source.includes(oldPluginBootstrapStart)) {
    source = source.replace(oldPluginBootstrapStart, newPluginBootstrapStart);
    changed = true;
  } else if (!source.includes("startupPluginsDisabled")) {
    throw new Error(`startup plugin bootstrap shape changed in ${serverImplPath}`);
  }

  const oldDeferredPluginIds = `\tconst deferredConfiguredChannelPluginIds = params.minimalTestGateway ? [] : resolveConfiguredDeferredChannelPluginIds({`;
  const newDeferredPluginIds = `\tconst deferredConfiguredChannelPluginIds = params.minimalTestGateway || startupPluginsDisabled ? [] : resolveConfiguredDeferredChannelPluginIds({`;
  if (source.includes(oldDeferredPluginIds)) {
    source = source.replace(oldDeferredPluginIds, newDeferredPluginIds);
    changed = true;
  } else if (!source.includes(newDeferredPluginIds)) {
    throw new Error(`deferred plugin id bootstrap shape changed in ${serverImplPath}`);
  }

  const oldStartupPluginIds = `\tconst startupPluginIds = params.minimalTestGateway ? [] : resolveGatewayStartupPluginIds({`;
  const newStartupPluginIds = `\tconst startupPluginIds = params.minimalTestGateway || startupPluginsDisabled ? [] : resolveGatewayStartupPluginIds({`;
  if (source.includes(oldStartupPluginIds)) {
    source = source.replace(oldStartupPluginIds, newStartupPluginIds);
    changed = true;
  } else if (!source.includes(newStartupPluginIds)) {
    throw new Error(`startup plugin id bootstrap shape changed in ${serverImplPath}`);
  }

  const oldPluginLoadGate = `\tif (!params.minimalTestGateway) ({pluginRegistry, gatewayMethods: baseGatewayMethods} = loadGatewayStartupPlugins({`;
  const newPluginLoadGate = `\tif (!params.minimalTestGateway && !startupPluginsDisabled) ({pluginRegistry, gatewayMethods: baseGatewayMethods} = loadGatewayStartupPlugins({`;
  if (source.includes(oldPluginLoadGate)) {
    source = source.replace(oldPluginLoadGate, newPluginLoadGate);
    changed = true;
  } else if (!source.includes(newPluginLoadGate)) {
    throw new Error(`startup plugin load gate shape changed in ${serverImplPath}`);
  }

  const oldUpdateCheck = `function scheduleGatewayUpdateCheck(params) {
\tlet stopped = false;`;
  const newUpdateCheck = `function scheduleGatewayUpdateCheck(params) {
\tif (isTruthyEnvValue(process.env.OPENCLAW_SKIP_STARTUP_UPDATE_CHECK)) return () => {};
\tlet stopped = false;`;
  if (source.includes(oldUpdateCheck)) {
    source = source.replace(oldUpdateCheck, newUpdateCheck);
    changed = true;
  } else if (!source.includes("OPENCLAW_SKIP_STARTUP_UPDATE_CHECK")) {
    throw new Error(`startup update check shape changed in ${serverImplPath}`);
  }

  const oldInternalHooks = `\ttry {
\t\tsetInternalHooksEnabled(params.cfg.hooks?.internal?.enabled !== false);
\t\tconst loadedCount = await loadInternalHooks(params.cfg, params.defaultWorkspaceDir);
\t\tif (loadedCount > 0) params.logHooks.info(\`loaded \${loadedCount} internal hook handler\${loadedCount > 1 ? "s" : ""}\`);
\t} catch (err) {
\t\tparams.logHooks.error(\`failed to load hooks: \${String(err)}\`);
\t}`;
  const newInternalHooks = `\tif (isTruthyEnvValue(process.env.OPENCLAW_SKIP_STARTUP_INTERNAL_HOOKS)) setInternalHooksEnabled(false);
\telse try {
\t\tsetInternalHooksEnabled(params.cfg.hooks?.internal?.enabled !== false);
\t\tconst loadedCount = await loadInternalHooks(params.cfg, params.defaultWorkspaceDir);
\t\tif (loadedCount > 0) params.logHooks.info(\`loaded \${loadedCount} internal hook handler\${loadedCount > 1 ? "s" : ""}\`);
\t} catch (err) {
\t\tparams.logHooks.error(\`failed to load hooks: \${String(err)}\`);
\t}`;
  if (source.includes(oldInternalHooks)) {
    source = source.replace(oldInternalHooks, newInternalHooks);
    changed = true;
  } else if (!source.includes("OPENCLAW_SKIP_STARTUP_INTERNAL_HOOKS")) {
    throw new Error(`startup internal hooks shape changed in ${serverImplPath}`);
  }

  const oldInternalHookTrigger = `\tif (params.cfg.hooks?.internal?.enabled !== false) setTimeout(() => {`;
  const newInternalHookTrigger = `\tif (!isTruthyEnvValue(process.env.OPENCLAW_SKIP_STARTUP_INTERNAL_HOOKS) && params.cfg.hooks?.internal?.enabled !== false) setTimeout(() => {`;
  if (source.includes(oldInternalHookTrigger)) {
    source = source.replace(oldInternalHookTrigger, newInternalHookTrigger);
    changed = true;
  } else if (!source.includes(newInternalHookTrigger)) {
    throw new Error(`startup internal hook trigger shape changed in ${serverImplPath}`);
  }

  const oldMemoryStartup = `\tstartGatewayMemoryBackend({
\t\tcfg: params.cfg,
\t\tlog: params.log
\t}).catch((err) => {
\t\tparams.log.warn(\`qmd memory startup initialization failed: \${String(err)}\`);
\t});`;
  const newMemoryStartup = `\tif (!isTruthyEnvValue(process.env.OPENCLAW_SKIP_STARTUP_MEMORY_BACKEND)) startGatewayMemoryBackend({
\t\tcfg: params.cfg,
\t\tlog: params.log
\t}).catch((err) => {
\t\tparams.log.warn(\`qmd memory startup initialization failed: \${String(err)}\`);
\t});`;
  if (source.includes(oldMemoryStartup)) {
    source = source.replace(oldMemoryStartup, newMemoryStartup);
    changed = true;
  } else if (!source.includes("OPENCLAW_SKIP_STARTUP_MEMORY_BACKEND")) {
    throw new Error(`startup memory backend shape changed in ${serverImplPath}`);
  }

  const oldOrphanRecovery = `\tscheduleSubagentOrphanRecovery();`;
  const newOrphanRecovery = `\tif (!isTruthyEnvValue(process.env.OPENCLAW_SKIP_STARTUP_ORPHAN_RECOVERY)) scheduleSubagentOrphanRecovery();`;
  if (source.includes(oldOrphanRecovery)) {
    source = source.replace(oldOrphanRecovery, newOrphanRecovery);
    changed = true;
  } else if (!source.includes("OPENCLAW_SKIP_STARTUP_ORPHAN_RECOVERY")) {
    throw new Error(`startup orphan recovery shape changed in ${serverImplPath}`);
  }

  if (changed) {
    fs.writeFileSync(serverImplPath, source);
    console.log(`patched ${serverImplPath}`);
  } else {
    console.log(`already patched ${serverImplPath}`);
  }
}
