#!/usr/bin/env node
// Haptix skill helper. Zero dependencies (Node 18+, built-in fetch).
//
// It never signs or sends anything. Write commands simulate the call against
// the chain, then print the `baw contract-call preview` command the agent runs
// next -- so every transaction still goes through Binance's preview and the
// user's own confirmation.
//
// Settings come from ../config.json, overridable by env:
//   HAPTIX_RPC_URL, HAPTIX_REGISTRY, HAPTIX_CHAIN_ID, HAPTIX_BINANCE_CHAIN_ID

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const fileCfg = JSON.parse(readFileSync(join(here, "..", "config.json"), "utf8"));
const ABI = JSON.parse(readFileSync(join(here, "..", "abi.json"), "utf8"));
const CFG = {
  rpcUrl: process.env.HAPTIX_RPC_URL || fileCfg.rpcUrl,
  registry: process.env.HAPTIX_REGISTRY || fileCfg.registry,
  chainId: Number(process.env.HAPTIX_CHAIN_ID || fileCfg.chainId),
  binanceChainId: process.env.HAPTIX_BINANCE_CHAIN_ID || fileCfg.binanceChainId,
};
const KIND = { rule: 0, allowance: 1, passkey: 2, delay: 3 };

// ---------------------------------------------------------------- encoding

const strip = (h) => h.replace(/^0x/, "");
const word = (n) => BigInt(n).toString(16).padStart(64, "0");
const addrWord = (a) => {
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) fail(`not an address: ${a}`);
  return strip(a).toLowerCase().padStart(64, "0");
};
const b32 = (h) => {
  if (!/^0x[0-9a-fA-F]{64}$/.test(h)) fail(`not a 32-byte hex value: ${h}`);
  return strip(h).toLowerCase();
};
const ruleWords = (r) => word(r.dailyCap) + word(r.ceiling) + word(r.passkeyAbove);
const bytesTail = (hex) => {
  const h = strip(hex);
  return word(h.length / 2) + h.padEnd(Math.ceil(h.length / 64) * 64, "0");
};
const sel = (name) => strip(ABI.registry[name] || fail(`unknown function ${name}`));

const enc = {
  open(token, rule, delay, pk) {
    // (TokenRule[] dynamic, uint32, (bytes32,bytes32)) -> head is 4 words
    return "0x" + sel("open") + word(0x80) + word(delay) + b32(pk.x) + b32(pk.y) +
      word(1) + addrWord(token) + ruleWords(rule);
  },
  tightenRule: (token, rule) => "0x" + sel("tightenRule") + addrWord(token) + ruleWords(rule),
  lengthenDelay: (d) => "0x" + sel("lengthenDelay") + word(d),
  ruleData: (token, rule) => "0x" + addrWord(token) + ruleWords(rule),
  delayData: (d) => "0x" + word(d),
  passkeyData: (pk) => "0x" + b32(pk.x) + b32(pk.y),
  kindBytes: (fn, kind, data) => "0x" + sel(fn) + word(kind) + word(0x40) + bytesTail(data),
  cancel: (id) => "0x" + sel("cancel") + b32(id),
};

// ---------------------------------------------------------------- chain

async function rpc(method, params) {
  const res = await fetch(CFG.rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await res.json();
  if (j.error) {
    const e = new Error(j.error.message || "rpc error");
    e.data = j.error.data;
    throw e;
  }
  return j.result;
}
const call = (to, data, from) => rpc("eth_call", [{ to, data, ...(from ? { from } : {}) }, "latest"]);
const words = (hex) => (strip(hex).match(/.{64}/g) || []).map((w) => BigInt("0x" + w));

function decodeRevert(err) {
  const data = typeof err.data === "string" ? err.data : err.data?.data;
  if (!data || data.length < 10) return err.message;
  const name = ABI.errors[data.slice(0, 10).toLowerCase()];
  return name ? name.replace(/\(.*$/, "") : `revert ${data.slice(0, 10)}`;
}

async function checkChain() {
  const id = Number(BigInt(await rpc("eth_chainId", [])));
  if (id !== CFG.chainId) fail(`RPC is on chain ${id}, expected ${CFG.chainId}`);
}

async function decimals(token) {
  return Number(BigInt(await call(token, ABI.erc20.decimals)));
}

async function symbol(token) {
  try {
    const r = strip(await call(token, ABI.erc20.symbol));
    const len = Number(BigInt("0x" + r.slice(64, 128)));
    return Buffer.from(r.slice(128, 128 + len * 2), "hex").toString("utf8");
  } catch {
    return token;
  }
}

// ---------------------------------------------------------------- units

function toUnits(amount, dec) {
  const s = String(amount);
  if (!/^\d+(\.\d+)?$/.test(s)) fail(`not a plain number: ${s}`);
  const [i, f = ""] = s.split(".");
  if (f.length > dec) fail(`${s} has more than ${dec} decimal places`);
  return BigInt(i) * 10n ** BigInt(dec) + BigInt(f.padEnd(dec, "0") || "0");
}

function fromUnits(v, dec) {
  const d = 10n ** BigInt(dec);
  const f = (v % d).toString().padStart(dec, "0").replace(/0+$/, "");
  return (v / d).toString() + (f ? "." + f : "");
}

function parseDelay(s) {
  const m = /^(\d+)\s*([smhd]?)$/.exec(String(s || "").trim());
  if (!m) fail(`delay must look like 3600, 90m, 24h or 2d -- got "${s}"`);
  const mult = { "": 1, s: 1, m: 60, h: 3600, d: 86400 }[m[2]];
  const v = Number(m[1]) * mult;
  if (v > 2 ** 32 - 1) fail("delay too long");
  return v;
}

// ---------------------------------------------------------------- reads

async function isHolder(addr) {
  return words(await call(CFG.registry, "0x" + sel("isHolder") + addrWord(addr)))[0] === 1n;
}

async function guardOf(addr) {
  const w = words(await call(CFG.registry, "0x" + sel("guardOf") + addrWord(addr)));
  return {
    open: w[0] === 1n,
    changeDelaySeconds: Number(w[1]),
    hasPasskey: w[2] !== 0n || w[3] !== 0n,
  };
}

async function ruleOf(addr, token) {
  const w = words(await call(CFG.registry, "0x" + sel("ruleOf") + addrWord(addr) + addrWord(token)));
  return { dailyCap: w[0], ceiling: w[1], passkeyAbove: w[2] };
}

// ---------------------------------------------------------------- writes

async function prepare(from, data, summary) {
  try {
    await call(CFG.registry, data, from);
  } catch (e) {
    return out({ ok: false, simulation: "reverted", reason: decodeRevert(e), summary });
  }
  out({
    ok: true,
    simulation: "ok",
    summary,
    next: "Run bawCommand, show the user the preview (parsed tx + risks), and only run " +
      "`baw contract-call execute --requestId <id> --json` after the user explicitly confirms.",
    bawCommand: `baw contract-call preview --binanceChainId ${CFG.binanceChainId} --from ${from} ` +
      `--to ${CFG.registry} --value 0 --inputData ${data} --json`,
  });
}

async function readRule(a) {
  const token = need(a, "token");
  const dec = await decimals(token);
  const rule = {
    dailyCap: toUnits(need(a, "daily"), dec),
    ceiling: toUnits(need(a, "ceiling"), dec),
    passkeyAbove: toUnits(need(a, "passkey-above"), dec),
  };
  if (rule.passkeyAbove > rule.ceiling || rule.ceiling > rule.dailyCap) {
    fail("need passkey-above <= ceiling <= daily");
  }
  const sym = await symbol(token);
  const human = `daily ${a.daily} ${sym}, max ${a.ceiling} ${sym} per payment, passkey above ${a["passkey-above"]} ${sym}`;
  return { token, rule, human };
}

const commands = {
  async status(a) {
    const addr = need(a, "address");
    const res = { address: addr, registry: CFG.registry, holdsAgentId: await isHolder(addr), guard: await guardOf(addr) };
    if (a.token) {
      const dec = await decimals(a.token);
      const r = await ruleOf(addr, a.token);
      res.rule = {
        token: a.token,
        symbol: await symbol(a.token),
        dailyCap: fromUnits(r.dailyCap, dec),
        ceiling: fromUnits(r.ceiling, dec),
        passkeyAbove: fromUnits(r.passkeyAbove, dec),
      };
    }
    out(res);
  },

  async open(a) {
    const from = need(a, "from");
    const { token, rule, human } = await readRule(a);
    const delay = parseDelay(need(a, "delay"));
    const zero = "0x" + "0".repeat(64);
    const pk = a["passkey-x"] || a["passkey-y"]
      ? { x: need(a, "passkey-x"), y: need(a, "passkey-y") }
      : { x: zero, y: zero };
    await prepare(from, enc.open(token, rule, delay, pk),
      `Open a Haptix guard: ${human}; raising any limit later waits ${a.delay}` +
      (pk.x === zero ? "; no passkey yet." : "; passkey set now."));
  },

  async "set-passkey"(a) {
    const from = need(a, "from");
    const g = await guardOf(from);
    await prepare(from, enc.kindBytes("queue", KIND.passkey, enc.passkeyData({ x: need(a, "x"), y: need(a, "y") })),
      `Queue this passkey for your guard. It applies after ${g.changeDelaySeconds}s; cancel any time before that.`);
  },

  async "apply-passkey"(a) {
    const from = need(a, "from");
    await prepare(from, enc.kindBytes("applyChange", KIND.passkey, enc.passkeyData({ x: need(a, "x"), y: need(a, "y") })),
      "Apply the queued passkey.");
  },

  async tighten(a) {
    const from = need(a, "from");
    const { token, rule, human } = await readRule(a);
    await prepare(from, enc.tightenRule(token, rule), `Lower limits now: ${human}.`);
  },

  async loosen(a) {
    const from = need(a, "from");
    const { token, rule, human } = await readRule(a);
    const g = await guardOf(from);
    await prepare(from, enc.kindBytes("queue", KIND.rule, enc.ruleData(token, rule)),
      `Queue higher limits (${human}). They apply only after ${g.changeDelaySeconds}s, and can be cancelled until then.`);
  },

  async "apply-loosen"(a) {
    const from = need(a, "from");
    const { token, rule, human } = await readRule(a);
    await prepare(from, enc.kindBytes("applyChange", KIND.rule, enc.ruleData(token, rule)),
      `Apply the queued limits: ${human}.`);
  },

  async "lengthen-delay"(a) {
    const from = need(a, "from");
    const d = parseDelay(need(a, "delay"));
    await prepare(from, enc.lengthenDelay(d), `Make limit increases wait ${a.delay}.`);
  },

  async "change-id"(a) {
    // Reads the id from the contract itself, so no keccak is needed here.
    // With --x/--y it's the id of a passkey change; otherwise a rule change.
    let kind = KIND.rule, data;
    if (a.x || a.y) {
      kind = KIND.passkey;
      data = enc.passkeyData({ x: need(a, "x"), y: need(a, "y") });
    } else {
      const { token, rule } = await readRule(a);
      data = enc.ruleData(token, rule);
    }
    const q = "0x" + sel("changeId") + word(kind) + word(0x40) + bytesTail(data);
    out({ id: await call(CFG.registry, q) });
  },

  async cancel(a) {
    const from = need(a, "from");
    await prepare(from, enc.cancel(need(a, "id")), `Cancel queued change ${a.id}.`);
  },

  async "encode-only"(a) {
    // Used by the test suite to compare against `cast calldata`.
    const zero = "0x" + "0".repeat(64);
    const rule = { dailyCap: BigInt(a.daily), ceiling: BigInt(a.ceiling), passkeyAbove: BigInt(a["passkey-above"]) };
    const map = {
      open: () => enc.open(a.token, rule, Number(a.delay), { x: zero, y: zero }),
      tighten: () => enc.tightenRule(a.token, rule),
      queue: () => enc.kindBytes("queue", KIND.rule, enc.ruleData(a.token, rule)),
      apply: () => enc.kindBytes("applyChange", KIND.rule, enc.ruleData(a.token, rule)),
    };
    console.log((map[a.fn] || (() => fail("unknown fn")))());
  },
};

// ---------------------------------------------------------------- cli

function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith("--")) fail(`unexpected argument ${argv[i]}`);
    a[argv[i].slice(2)] = argv[i + 1];
    i++;
  }
  return a;
}
function need(a, k) {
  if (a[k] === undefined || a[k] === "") fail(`missing --${k}`);
  return a[k];
}
function out(o) {
  console.log(JSON.stringify(o, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
}
function fail(msg) {
  out({ ok: false, error: msg });
  process.exit(1);
}

const [cmd, ...rest] = process.argv.slice(2);
if (!commands[cmd]) {
  fail(`usage: haptix.mjs <${Object.keys(commands).filter((c) => c !== "encode-only").join("|")}> --flag value ...`);
}
const args = parseArgs(rest);
if (cmd !== "encode-only") await checkChain();
await commands[cmd](args);
