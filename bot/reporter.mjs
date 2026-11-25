#!/usr/bin/env node
// Tapster reporter bot.
//
// Every round, for every feed, it fetches the price from several public
// exchanges, takes the median, refuses to report when the sources disagree
// (so an honest reporter is never slashed for a bad source), and submits
// the price with gnokey. One process can run several reporter keys.
//
//   node reporter.mjs            run forever
//   node reporter.mjs --once     report one round and exit
//   node reporter.mjs --dry-run  print prices, submit nothing
//
// Configuration is read from .env next to this file (see .env.example).
// Needs Node 18+ (built-in fetch) and gnokey on PATH or at GNOKEY.

import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
loadEnv(join(here, ".env"));

const cfg = {
  gnokey: process.env.GNOKEY || "gnokey",
  home: process.env.GNOKEY_HOME || "",
  keys: (process.env.REPORTER_KEYS || "tapster-admin").split(",").map((s) => s.trim()).filter(Boolean),
  password: process.env.KEY_PASSWORD ?? "",
  realm: required("TAPSTER_REALM"), // gno.land/r/<addr>/tapster/v0
  chainId: process.env.CHAIN_ID || "onyx-1",
  rpc: process.env.RPC || "https://rpc.onyx.testnets.gno.land:443",
  pairs: (process.env.PAIRS || "GNOT-USD,BTC-USD,ETH-USD,XAU-USD").split(",").map((s) => s.trim()),
  maxSourceSpreadBps: Number(process.env.MAX_SOURCE_SPREAD_BPS || 200),
  gasWanted: process.env.GAS_WANTED || "30000000",
  gasFee: process.env.GAS_FEE || "40000ugnot",
  // Demo only: this key reports a price this many bps too high, to show
  // slashing live. Never set it on a real reporter.
  chaosKey: process.env.CHAOS_KEY || "",
  chaosBps: Number(process.env.CHAOS_BPS || 3000),
};
const args = new Set(process.argv.slice(2));
const DRY = args.has("--dry-run");
const ONCE = args.has("--once");

// ---------------------------------------------------------------------------
// Price sources. Each returns a USD price as a Number, or throws.

const j = async (url) => {
  const ctl = AbortSignal.timeout(8000);
  const r = await fetch(url, { signal: ctl, headers: { "user-agent": "tapster-reporter/1.0" } });
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return r.json();
};

let cgCache = { at: 0, data: null };
async function coingecko(id) {
  if (Date.now() - cgCache.at > 20000) {
    cgCache = {
      at: Date.now(),
      data: await j("https://api.coingecko.com/api/v3/simple/price?ids=gno-land,bitcoin,ethereum,pax-gold&vs_currencies=usd"),
    };
  }
  const v = cgCache.data?.[id]?.usd;
  if (!v) throw new Error("coingecko: no " + id);
  return Number(v);
}
let krCache = { at: 0, data: null };
async function kraken(key) {
  if (Date.now() - krCache.at > 20000) {
    krCache = { at: Date.now(), data: await j("https://api.kraken.com/0/public/Ticker?pair=GNOTUSD,XBTUSD,ETHUSD,PAXGUSD") };
  }
  const v = krCache.data?.result?.[key]?.c?.[0];
  if (!v) throw new Error("kraken: no " + key);
  return Number(v);
}
const coinbase = async (p) => Number((await j(`https://api.coinbase.com/v2/prices/${p}/spot`)).data.amount);
const okx = async (inst) => Number((await j(`https://www.okx.com/api/v5/market/ticker?instId=${inst}`)).data[0].last);
const kucoin = async (sym) => Number((await j(`https://api.kucoin.com/api/v1/market/orderbook/level1?symbol=${sym}`)).data.price);

// XAU-USD uses PAX Gold (PAXG), a token backed 1:1 by a troy ounce of gold.
const SOURCES = {
  "GNOT-USD": { coingecko: () => coingecko("gno-land"), kraken: () => kraken("GNOTUSD"), kucoin: () => kucoin("GNOT-USDT") },
  "BTC-USD": { coingecko: () => coingecko("bitcoin"), kraken: () => kraken("XXBTZUSD"), coinbase: () => coinbase("BTC-USD"), okx: () => okx("BTC-USDT") },
  "ETH-USD": { coingecko: () => coingecko("ethereum"), kraken: () => kraken("XETHZUSD"), coinbase: () => coinbase("ETH-USD"), okx: () => okx("ETH-USDT") },
  "XAU-USD": { coingecko: () => coingecko("pax-gold"), kraken: () => kraken("PAXGUSD"), coinbase: () => coinbase("PAXG-USD") },
};

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};

// FAKE_PRICES=1 replaces the exchanges with a small random walk, for local
// testing against gnodev without network access.
const FAKE_BASE = { "GNOT-USD": 0.05, "BTC-USD": 60000, "ETH-USD": 1690, "XAU-USD": 3570 };
const fakeState = {};
function fakeSources(pair) {
  const b = (fakeState[pair] ??= FAKE_BASE[pair] ?? 1) * (1 + (Math.random() - 0.5) * 0.004);
  fakeState[pair] = b;
  return { fake1: async () => b, fake2: async () => b * 1.0005, fake3: async () => b * 0.9995 };
}

async function priceFor(pair) {
  const srcs = process.env.FAKE_PRICES === "1" ? fakeSources(pair) : SOURCES[pair];
  if (!srcs) throw new Error("no sources for " + pair);
  const got = {};
  await Promise.all(
    Object.entries(srcs).map(async ([name, fn]) => {
      try {
        const v = await fn();
        if (Number.isFinite(v) && v > 0) got[name] = v;
      } catch (e) {
        /* a failing source is skipped */
      }
    }),
  );
  const vals = Object.values(got);
  if (vals.length === 0) throw new Error(`${pair}: every source failed`);
  const m = median(vals);
  const spreadBps = ((Math.max(...vals) - Math.min(...vals)) / m) * 10000;
  return { pair, price: m, sources: got, spreadBps };
}

// ---------------------------------------------------------------------------
// Chain access

async function rpc(method, params) {
  const r = await fetch(cfg.rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(10000),
  });
  const body = await r.json();
  return body.result;
}

async function render(path) {
  const data = Buffer.from(`${cfg.realm}:${path}`).toString("base64");
  const res = await rpc("abci_query", { path: "vm/qrender", data });
  const rb = res?.response?.ResponseBase;
  if (rb?.Error) throw new Error("qrender: " + JSON.stringify(rb.Error).slice(0, 200));
  return Buffer.from(rb.Data, "base64").toString();
}

async function feeds() {
  const all = JSON.parse(await render("json"));
  const m = {};
  for (const f of all.feeds) m[f.pair] = f;
  return m;
}

// gnokey locks its key store; retry briefly if another gnokey holds it.
async function gnokeyCall(key, func, args) {
  for (let i = 0; i < 4; i++) {
    const r = await gnokeyOnce(key, func, args);
    if (!/resource temporarily unavailable|error initializing DB/.test(r.out)) return r;
    await sleep(1500 + Math.random() * 1500);
  }
  return gnokeyOnce(key, func, args);
}

function gnokeyOnce(key, func, args) {
  const argv = ["maketx", "call", "-pkgpath", cfg.realm, "-func", func];
  for (const a of args) argv.push("-args", String(a));
  argv.push("-gas-fee", cfg.gasFee, "-gas-wanted", cfg.gasWanted, "-broadcast", "-chainid", cfg.chainId, "-remote", cfg.rpc, "-insecure-password-stdin");
  if (cfg.home) argv.push("-home", cfg.home);
  argv.push(key);
  return new Promise((resolve) => {
    const p = spawn(cfg.gnokey, argv, { stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (out += d));
    p.stdin.end(cfg.password + "\n");
    p.on("close", (code) => resolve({ ok: code === 0 && out.includes("OK!"), out }));
    p.on("error", (e) => resolve({ ok: false, out: String(e) }));
  });
}

const toInt = (price, decimals) => BigInt(Math.round(price * 10 ** decimals));
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Main loop

const reported = new Map(); // `${key}|${pair}` -> round id

async function tick() {
  let fs;
  try {
    fs = await feeds();
  } catch (e) {
    log("cannot read feeds:", e.message);
    return;
  }
  const nowS = Math.floor(Date.now() / 1000);
  for (const pair of cfg.pairs) {
    const f = fs[pair];
    if (!f) {
      log(`${pair}: not a feed on this realm, skipping`);
      continue;
    }
    if (f.paused) continue;
    const round = Math.floor(nowS / f.roundSecs);
    const pending = cfg.keys.filter((k) => reported.get(`${k}|${pair}`) !== round);
    if (pending.length === 0) continue;

    let q;
    try {
      q = await priceFor(pair);
    } catch (e) {
      log(e.message);
      continue;
    }
    const srcTxt = Object.entries(q.sources).map(([k, v]) => `${k}=${v}`).join(" ");
    if (q.spreadBps > cfg.maxSourceSpreadBps) {
      log(`${pair}: sources disagree by ${(q.spreadBps / 100).toFixed(2)}%, not reporting this round (${srcTxt})`);
      continue;
    }
    for (const key of pending) {
      let p = q.price;
      if (key === cfg.chaosKey) p = p * (1 + cfg.chaosBps / 10000);
      const v = toInt(p, f.decimals);
      if (DRY) {
        log(`[dry] ${key} ${pair} ${p} -> ${v} (${srcTxt})`);
        reported.set(`${key}|${pair}`, round);
        continue;
      }
      const res = await gnokeyCall(key, "Submit", [pair, v.toString()]);
      if (res.ok) {
        log(`${key} ${pair} = ${p} (round ${round}; ${srcTxt})`);
        reported.set(`${key}|${pair}`, round);
      } else if (res.out.includes("already reported")) {
        reported.set(`${key}|${pair}`, round);
      } else {
        const why = res.out.match(/VM panic: (.*)/)?.[1] || res.out.split("\n").find((l) => /panic|error/i.test(l) && !/^--= Error/.test(l.trim())) || res.out.slice(0, 300);
        log(`${key} ${pair} failed: ${why.trim()}`);
      }
    }
  }
}

function required(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing ${name}. Copy .env.example to .env and fill it in.`);
    process.exit(1);
  }
  return v;
}

function loadEnv(file) {
  if (!existsSync(file)) return;
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}

log(`Tapster reporter: ${cfg.keys.join(", ")} -> ${cfg.realm} on ${cfg.chainId}${DRY ? " (dry run)" : ""}`);
if (ONCE) {
  await tick();
} else {
  for (;;) {
    await tick();
    await sleep(15000 + Math.random() * 10000);
  }
}
