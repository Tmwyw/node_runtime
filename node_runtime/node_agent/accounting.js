"use strict";

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const PROXY_ROOT = path.normalize(process.env.NODE_AGENT_PROXY_ROOT || "/opt/netrun/proxyserver");
const PROXY_CFG_DIR = path.join(PROXY_ROOT, "3proxy");
const PROXY_BIN = path.join(PROXY_ROOT, "3proxy", "bin", "3proxy");
const NFT_TABLE = "proxy_accounting";
const COUNTER_NAME_RE = /^proxy_(\d+)_(in6|in|out)$/;

class PortNotFoundError extends Error {
  constructor(port) {
    super(`port_not_found: ${port}`);
    this.name = "PortNotFoundError";
    this.code = "PORT_NOT_FOUND";
    this.port = port;
  }
}

class NftablesError extends Error {
  constructor(message, detail) {
    super(message);
    this.name = "NftablesError";
    this.code = "NFTABLES_ERROR";
    this.detail = detail;
  }
}

class ProcessSpawnError extends Error {
  constructor(message, detail) {
    super(message);
    this.name = "ProcessSpawnError";
    this.code = "PROCESS_SPAWN_ERROR";
    this.detail = detail;
  }
}

function execCapture(cmd, args, { timeoutMs = 5000 } = {}) {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let settled = false;
    let child;
    try {
      child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
    } catch (err) {
      resolve({ code: -1, stdout: "", stderr: String(err && err.message || err), spawnError: err });
      return;
    }
    const timer = setTimeout(() => {
      if (settled) return;
      try { child.kill("SIGKILL"); } catch {}
    }, timeoutMs);
    child.stdout.on("data", (d) => { stdout += d.toString("utf-8"); });
    child.stderr.on("data", (d) => { stderr += d.toString("utf-8"); });
    child.on("error", (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: stderr || String(err && err.message || err), spawnError: err });
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ code: typeof code === "number" ? code : -1, stdout, stderr });
    });
  });
}

function configPathForPort(port) {
  return path.join(PROXY_CFG_DIR, `3proxy_${port}.cfg`);
}

async function findRunningPids(port) {
  const pattern = `3proxy_${port}.cfg`;
  const result = await execCapture("pgrep", ["-f", pattern]);
  if (result.code === 0) {
    return result.stdout
      .split(/\s+/)
      .map((s) => s.trim())
      .filter((s) => /^\d+$/.test(s))
      .map(Number);
  }
  if (result.code === 1) {
    return [];
  }
  throw new ProcessSpawnError("pgrep_failed", result.stderr || `exit ${result.code}`);
}

async function getCountersForPorts(ports) {
  const requested = new Set(
    (ports || [])
      .map((p) => Number(p))
      .filter((p) => Number.isInteger(p) && p > 0)
  );
  if (requested.size === 0) return {};

  const result = await execCapture("nft", ["-j", "list", "counters", "table", "inet", NFT_TABLE]);
  if (result.code !== 0) {
    throw new NftablesError("nft_list_counters_failed", result.stderr || `exit ${result.code}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(result.stdout || "{}");
  } catch (err) {
    throw new NftablesError("nft_json_parse_failed", String(err && err.message || err));
  }
  const items = Array.isArray(parsed && parsed.nftables) ? parsed.nftables : [];

  const buckets = new Map();
  for (const item of items) {
    if (!item || typeof item !== "object") continue;
    const counter = item.counter;
    if (!counter || typeof counter !== "object") continue;
    if (counter.family !== "inet" || counter.table !== NFT_TABLE) continue;
    const m = COUNTER_NAME_RE.exec(String(counter.name || ""));
    if (!m) continue;
    const port = Number(m[1]);
    const kind = m[2];
    if (!requested.has(port)) continue;
    if (!buckets.has(port)) buckets.set(port, { in: 0, out: 0, in6: 0, present: false });
    const bucket = buckets.get(port);
    bucket.present = true;
    bucket[kind] = Number(counter.bytes) || 0;
  }

  const out = {};
  for (const [port, b] of buckets) {
    if (!b.present) continue;
    out[String(port)] = {
      bytes_in: b.in + b.in6,
      bytes_out: b.out,
    };
  }
  return out;
}

async function disablePort(port) {
  const portNum = Number(port);
  if (!Number.isInteger(portNum) || portNum <= 0) {
    throw new PortNotFoundError(port);
  }
  const cfg = configPathForPort(portNum);
  const cfgExists = fs.existsSync(cfg);
  const pids = await findRunningPids(portNum);

  if (pids.length === 0) {
    if (!cfgExists) {
      const counters = await getCountersForPorts([portNum]).catch(() => ({}));
      if (!counters[String(portNum)]) {
        throw new PortNotFoundError(portNum);
      }
    }
    return { action: "already_disabled" };
  }

  for (const pid of pids) {
    try {
      process.kill(pid, "SIGTERM");
    } catch (err) {
      if (err && err.code !== "ESRCH") {
        throw new ProcessSpawnError("kill_failed", String(err && err.message || err));
      }
    }
  }
  return { action: "killed", pids };
}

async function enablePort(port) {
  const portNum = Number(port);
  if (!Number.isInteger(portNum) || portNum <= 0) {
    throw new PortNotFoundError(port);
  }
  const cfg = configPathForPort(portNum);
  if (!fs.existsSync(cfg)) {
    throw new PortNotFoundError(portNum);
  }

  const pids = await findRunningPids(portNum);
  if (pids.length > 0) {
    return { action: "already_enabled", pids };
  }

  if (!fs.existsSync(PROXY_BIN)) {
    throw new ProcessSpawnError("3proxy_binary_missing", PROXY_BIN);
  }

  let child;
  try {
    child = spawn(PROXY_BIN, [cfg], {
      detached: true,
      stdio: "ignore",
    });
  } catch (err) {
    throw new ProcessSpawnError("3proxy_spawn_failed", String(err && err.message || err));
  }
  const pid = child.pid;
  child.unref();
  return { action: "started", pid };
}

module.exports = {
  getCountersForPorts,
  disablePort,
  enablePort,
  PortNotFoundError,
  NftablesError,
  ProcessSpawnError,
};
