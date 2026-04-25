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
const depsFiles = fs
  .readdirSync(distDir)
  .filter((name) => /^deps-.+\.js$/.test(name));
const netFiles = fs
  .readdirSync(distDir)
  .filter((name) => /^net-.+\.js$/.test(name));
const ioFiles = fs
  .readdirSync(distDir)
  .filter((name) => /^io-.+\.js$/.test(name));
const pluginAutoEnableFiles = fs
  .readdirSync(distDir)
  .filter((name) => /^plugin-auto-enable-.+\.js$/.test(name));

if (serverImplFiles.length === 0) {
  throw new Error(`server impl bundle not found in ${distDir}`);
}
if (depsFiles.length === 0) {
  throw new Error(`deps bundle not found in ${distDir}`);
}
if (netFiles.length === 0) {
  throw new Error(`net bundle not found in ${distDir}`);
}
if (ioFiles.length === 0) {
  throw new Error(`io bundle not found in ${distDir}`);
}
if (pluginAutoEnableFiles.length === 0) {
  throw new Error(`plugin auto-enable bundle not found in ${distDir}`);
}

for (const netFile of netFiles) {
  const netPath = path.join(distDir, netFile);
  source = fs.readFileSync(netPath, "utf8");
  changed = false;

  const oldLoopbackBindFallback = `\tif (mode === "loopback") {
\t\tif (await canBindToHost("127.0.0.1")) return "127.0.0.1";
\t\treturn "0.0.0.0";
\t}`;
  const newLoopbackBindFallback = `\tif (mode === "loopback") return "127.0.0.1";`;
  if (source.includes(oldLoopbackBindFallback)) {
    source = source.replace(oldLoopbackBindFallback, newLoopbackBindFallback);
    changed = true;
  } else if (!source.includes(newLoopbackBindFallback)) {
    throw new Error(`loopback bind fallback shape changed in ${netPath}`);
  }

  if (changed) {
    fs.writeFileSync(netPath, source);
    console.log(`patched ${netPath}`);
  } else {
    console.log(`already patched ${netPath}`);
  }
}

for (const pluginAutoEnableFile of pluginAutoEnableFiles) {
  const pluginAutoEnablePath = path.join(distDir, pluginAutoEnableFile);
  source = fs.readFileSync(pluginAutoEnablePath, "utf8");
  changed = false;

  const oldApplyPluginAutoEnable = `function applyPluginAutoEnable(params) {
\tconst candidates = detectPluginAutoEnableCandidates(params);`;
  const newApplyPluginAutoEnable = `function applyPluginAutoEnable(params) {
\tconst env = params.env ?? process.env;
\tconst skipStartupPlugins = ["1", "true", "yes", "on"].includes(String(env.OPENCLAW_SKIP_STARTUP_PLUGINS ?? "").trim().toLowerCase());
\tif (skipStartupPlugins || params.config?.plugins?.enabled === false) return {
\t\tconfig: params.config,
\t\tchanges: [],
\t\tautoEnabledReasons: {}
\t};
\tconst candidates = detectPluginAutoEnableCandidates(params);`;
  if (source.includes(oldApplyPluginAutoEnable)) {
    source = source.replace(oldApplyPluginAutoEnable, newApplyPluginAutoEnable);
    changed = true;
  } else if (!source.includes(newApplyPluginAutoEnable)) {
    throw new Error(`plugin auto-enable shape changed in ${pluginAutoEnablePath}`);
  }

  if (changed) {
    fs.writeFileSync(pluginAutoEnablePath, source);
    console.log(`patched ${pluginAutoEnablePath}`);
  } else {
    console.log(`already patched ${pluginAutoEnablePath}`);
  }
}

for (const ioFile of ioFiles) {
  const ioPath = path.join(distDir, ioFile);
  source = fs.readFileSync(ioPath, "utf8");
  changed = false;
  if (!source.includes("function validateConfigObjectWithPluginsBase")) {
    console.log(`skipping ${ioPath}`);
    continue;
  }

  const oldPluginValidationState = `\tconst config = base.config;
\tconst issues = [];
\tconst warnings = [];`;
  const newPluginValidationState = `\tconst config = base.config;
\tconst startupPluginsDisabled = ["1", "true", "yes", "on"].includes(String(opts.env?.OPENCLAW_SKIP_STARTUP_PLUGINS ?? "").trim().toLowerCase()) || config.plugins?.enabled === false;
\tconst isDisabledExternalChannelConfig = (value) => value === false || value && typeof value === "object" && value.enabled === false;
\tconst issues = [];
\tconst warnings = [];`;
  if (source.includes(oldPluginValidationState)) {
    source = source.replace(oldPluginValidationState, newPluginValidationState);
    changed = true;
  } else if (!source.includes(newPluginValidationState)) {
    throw new Error(`plugin validation state shape changed in ${ioPath}`);
  }

  const oldUnknownChannelRegistry = `\t\tif (!allowedChannels.has(trimmed)) {
\t\t\tconst { registry } = ensureRegistry();
\t\t\tfor (const record of registry.plugins) for (const channelId of record.channels) allowedChannels.add(channelId);
\t\t}
\t\tif (!allowedChannels.has(trimmed)) {
\t\t\tissues.push({`;
  const newUnknownChannelRegistry = `\t\tif (!allowedChannels.has(trimmed)) {
\t\t\tif (!startupPluginsDisabled) {
\t\t\t\tconst { registry } = ensureRegistry();
\t\t\t\tfor (const record of registry.plugins) for (const channelId of record.channels) allowedChannels.add(channelId);
\t\t\t}
\t\t}
\t\tif (!allowedChannels.has(trimmed)) {
\t\t\tif (startupPluginsDisabled && isDisabledExternalChannelConfig(config.channels[trimmed])) continue;
\t\t\tissues.push({`;
  if (source.includes(oldUnknownChannelRegistry)) {
    source = source.replace(oldUnknownChannelRegistry, newUnknownChannelRegistry);
    changed = true;
  } else if (!source.includes("isDisabledExternalChannelConfig(config.channels[trimmed])")) {
    throw new Error(`unknown channel registry shape changed in ${ioPath}`);
  }

  const oldExplicitPluginConfigGate = `\tif (!hasExplicitPluginsConfig) {`;
  const newExplicitPluginConfigGate = `\tif (!hasExplicitPluginsConfig || startupPluginsDisabled) {`;
  if (source.includes(oldExplicitPluginConfigGate)) {
    source = source.replace(oldExplicitPluginConfigGate, newExplicitPluginConfigGate);
    changed = true;
  } else if (!source.includes(newExplicitPluginConfigGate)) {
    throw new Error(`explicit plugin config gate shape changed in ${ioPath}`);
  }

  if (changed) {
    fs.writeFileSync(ioPath, source);
    console.log(`patched ${ioPath}`);
  } else {
    console.log(`already patched ${ioPath}`);
  }
}

for (const depsFile of depsFiles) {
  const depsPath = path.join(distDir, depsFile);
  source = fs.readFileSync(depsPath, "utf8");
  changed = false;

  const oldCreateDefaultDeps = `function createDefaultDeps() {
\tconst deps = {};
\tfor (const plugin of listChannelPlugins()) deps[plugin.id] = createLazySender(plugin.id, async () => ({ runtimeSend: createChannelOutboundRuntimeSend({`;
  const newCreateDefaultDeps = `function createDefaultDeps(channelPlugins) {
\tconst deps = {};
\tfor (const plugin of channelPlugins ?? listChannelPlugins()) deps[plugin.id] = createLazySender(plugin.id, async () => ({ runtimeSend: createChannelOutboundRuntimeSend({`;
  if (source.includes(oldCreateDefaultDeps)) {
    source = source.replace(oldCreateDefaultDeps, newCreateDefaultDeps);
    changed = true;
  } else if (!source.includes(newCreateDefaultDeps)) {
    throw new Error(`createDefaultDeps shape changed in ${depsPath}`);
  }

  if (changed) {
    fs.writeFileSync(depsPath, source);
    console.log(`patched ${depsPath}`);
  } else {
    console.log(`already patched ${depsPath}`);
  }
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

  const oldChannelManagerStart = `function createChannelManager(opts) {
\tconst { loadConfig, channelLogs, channelRuntimeEnvs, channelRuntime, resolveChannelRuntime } = opts;
\tconst channelStores = /* @__PURE__ */ new Map();`;
  const newChannelManagerStart = `function createChannelManager(opts) {
\tconst { loadConfig, channelLogs, channelRuntimeEnvs, channelRuntime, resolveChannelRuntime, listStartupChannelPlugins } = opts;
\tconst channelStores = /* @__PURE__ */ new Map();`;
  if (source.includes(oldChannelManagerStart)) {
    source = source.replace(oldChannelManagerStart, newChannelManagerStart);
    changed = true;
  } else if (!source.includes(newChannelManagerStart)) {
    throw new Error(`channel manager options shape changed in ${serverImplPath}`);
  }

  const oldManagedChannelAnchor = `\tconst manuallyStopped = /* @__PURE__ */ new Set();
\tconst restartKey = (channelId, accountId) => \`\${channelId}:\${accountId}\`;`;
  const newManagedChannelAnchor = `\tconst manuallyStopped = /* @__PURE__ */ new Set();
\tconst listManagedChannelPlugins = () => listStartupChannelPlugins?.() ?? listChannelPlugins();
\tconst restartKey = (channelId, accountId) => \`\${channelId}:\${accountId}\`;`;
  if (source.includes(oldManagedChannelAnchor)) {
    source = source.replace(oldManagedChannelAnchor, newManagedChannelAnchor);
    changed = true;
  } else if (!source.includes(newManagedChannelAnchor)) {
    throw new Error(`channel manager plugin list anchor changed in ${serverImplPath}`);
  }

  const oldStartChannelsLoop = `\tconst startChannels = async () => {
\t\tfor (const plugin of listChannelPlugins()) try {`;
  const newStartChannelsLoop = `\tconst startChannels = async () => {
\t\tfor (const plugin of listManagedChannelPlugins()) try {`;
  if (source.includes(oldStartChannelsLoop)) {
    source = source.replace(oldStartChannelsLoop, newStartChannelsLoop);
    changed = true;
  } else if (!source.includes(newStartChannelsLoop)) {
    throw new Error(`startChannels loop shape changed in ${serverImplPath}`);
  }

  const oldRuntimeSnapshotLoop = `\t\tfor (const plugin of listChannelPlugins()) {
\t\t\tconst store = getStore(plugin.id);`;
  const newRuntimeSnapshotLoop = `\t\tfor (const plugin of listManagedChannelPlugins()) {
\t\t\tconst store = getStore(plugin.id);`;
  if (source.includes(oldRuntimeSnapshotLoop)) {
    source = source.replace(oldRuntimeSnapshotLoop, newRuntimeSnapshotLoop);
    changed = true;
  } else if (!source.includes(newRuntimeSnapshotLoop)) {
    throw new Error(`runtime snapshot channel loop shape changed in ${serverImplPath}`);
  }

  const oldStartGatewayServer = `async function startGatewayServer(port = 18789, opts = {}) {`;
  const newStartGatewayServer = `function shouldLimitGatewayStartupChannelPlugins() {
\treturn isTruthyEnvValue(process.env.OPENCLAW_SKIP_INACTIVE_CHANNEL_PLUGINS);
}
function listGatewayStartupChannelPlugins(cfg) {
\tif (!shouldLimitGatewayStartupChannelPlugins()) return listChannelPlugins();
\tconst channels = cfg?.channels;
\tif (!channels || typeof channels !== "object") return [];
\tconst plugins = [];
\tconst seen = /* @__PURE__ */ new Set();
\tfor (const [id, value] of Object.entries(channels)) {
\t\tif (id === "defaults" || value === false) continue;
\t\tif (value && typeof value === "object" && value.enabled === false) continue;
\t\tif (!(value === true || value && typeof value === "object")) continue;
\t\tconst plugin = getChannelPlugin(id);
\t\tif (!plugin || seen.has(plugin.id)) continue;
\t\tseen.add(plugin.id);
\t\tplugins.push(plugin);
\t}
\treturn plugins;
}
async function startGatewayServer(port = 18789, opts = {}) {`;
  if (source.includes(newStartGatewayServer)) {
    // Already patched.
  } else if (source.includes(oldStartGatewayServer)) {
    source = source.replace(oldStartGatewayServer, newStartGatewayServer);
    changed = true;
  } else {
    throw new Error(`startGatewayServer shape changed in ${serverImplPath}`);
  }

  const oldStartupChannelLogs = `\tconst channelLogs = Object.fromEntries(listChannelPlugins().map((plugin) => [plugin.id, logChannels.child(plugin.id)]));
\tconst channelRuntimeEnvs = Object.fromEntries(Object.entries(channelLogs).map(([id, logger]) => [id, runtimeForLogger(logger)]));
\tconst listActiveGatewayMethods = (nextBaseGatewayMethods) => Array.from(new Set([...nextBaseGatewayMethods, ...listChannelPlugins().flatMap((plugin) => plugin.gatewayMethods ?? [])]));`;
  const newStartupChannelLogs = `\tconst startupChannelPlugins = listGatewayStartupChannelPlugins(cfgAtStart);
\tconst listGatewayRuntimeChannelPlugins = () => shouldLimitGatewayStartupChannelPlugins() ? startupChannelPlugins : listChannelPlugins();
\tconst channelLogs = Object.fromEntries(startupChannelPlugins.map((plugin) => [plugin.id, logChannels.child(plugin.id)]));
\tconst channelRuntimeEnvs = Object.fromEntries(Object.entries(channelLogs).map(([id, logger]) => [id, runtimeForLogger(logger)]));
\tconst listActiveGatewayMethods = (nextBaseGatewayMethods) => Array.from(new Set([...nextBaseGatewayMethods, ...listGatewayRuntimeChannelPlugins().flatMap((plugin) => plugin.gatewayMethods ?? [])]));`;
  if (source.includes(oldStartupChannelLogs)) {
    source = source.replace(oldStartupChannelLogs, newStartupChannelLogs);
    changed = true;
  } else if (!source.includes(newStartupChannelLogs)) {
    throw new Error(`startup channel logs shape changed in ${serverImplPath}`);
  }

  const oldDefaultDeps = `\tconst deps = createDefaultDeps();`;
  const newDefaultDeps = `\tconst deps = shouldLimitGatewayStartupChannelPlugins() ? createDefaultDeps(startupChannelPlugins) : createDefaultDeps();`;
  if (source.includes(oldDefaultDeps)) {
    source = source.replace(oldDefaultDeps, newDefaultDeps);
    changed = true;
  } else if (!source.includes(newDefaultDeps)) {
    throw new Error(`startup deps shape changed in ${serverImplPath}`);
  }

  const oldChannelManagerOptions = `\t\tchannelLogs,
\t\tchannelRuntimeEnvs,
\t\tresolveChannelRuntime: getChannelRuntime`;
  const newChannelManagerOptions = `\t\tchannelLogs,
\t\tchannelRuntimeEnvs,
\t\tlistStartupChannelPlugins: listGatewayRuntimeChannelPlugins,
\t\tresolveChannelRuntime: getChannelRuntime`;
  if (source.includes(oldChannelManagerOptions)) {
    source = source.replace(oldChannelManagerOptions, newChannelManagerOptions);
    changed = true;
  } else if (!source.includes("listStartupChannelPlugins: listGatewayRuntimeChannelPlugins")) {
    throw new Error(`channel manager startup plugin option shape changed in ${serverImplPath}`);
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
