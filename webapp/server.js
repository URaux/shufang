// 群星阅览室 server — chat (wraps Claude Code headless) + vault markdown reader.
//
// Config lives in ~/.shufang/config.json:
//   {
//     "vaultPath": "C:\\Users\\me\\Documents\\书房",
//     "port": 7787,
//     "token": "random-string",          // gates non-localhost access
//     "env": {                            // injected into every claude spawn
//       "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
//       "ANTHROPIC_AUTH_TOKEN": "sk-...",
//       "ANTHROPIC_MODEL": "deepseek-v4-pro",
//       "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro",
//       "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro",
//       "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
//       "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash"
//     }
//   }
//
// Design notes:
// - Localhost requests skip the token so the Obsidian web-viewer pane just works.
//   LAN requests need ?t=<token> once; a cookie keeps them signed in after that.
// - One conversation per vault via `claude --continue`; the first message ever
//   omits --continue (nothing to continue into) and drops a flag file after.
// - Chat replies stream over SSE. We forward text deltas when
//   --include-partial-messages provides them and fall back to whole assistant
//   messages otherwise, so it works across Claude Code versions.

const express = require("express");
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { marked } = require("marked");
const qrcode = require("qrcode-terminal");

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const CONFIG_DIR = path.join(os.homedir(), ".shufang");
const CONFIG_PATH = path.join(CONFIG_DIR, "config.json");

function loadConfig() {
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8")); } catch { /* first run */ }
  cfg.vaultPath = cfg.vaultPath || path.join(os.homedir(), "Documents", "书房");
  cfg.port = cfg.port || 7787;
  if (!cfg.token) {
    cfg.token = crypto.randomBytes(8).toString("hex");
    try {
      fs.mkdirSync(CONFIG_DIR, { recursive: true });
      fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2));
    } catch { /* non-fatal: token just won't persist */ }
  }
  cfg.env = cfg.env || {};
  return cfg;
}

const cfg = loadConfig();
const VAULT = path.resolve(cfg.vaultPath);
const LIBRARY = path.join(VAULT, "Library");
const SESSION_FLAG = path.join(VAULT, ".shufang-session-started");

if (!fs.existsSync(VAULT)) {
  console.error(`[群星阅览室] 找不到书库文件夹: ${VAULT}`);
  console.error(`[群星阅览室] 请检查 ${CONFIG_PATH} 里的 vaultPath，或重跑安装器。`);
  process.exit(1);
}
fs.mkdirSync(LIBRARY, { recursive: true });

// ---------------------------------------------------------------------------
// App + auth
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: "2mb" }));

function isLocal(req) {
  const ip = req.socket.remoteAddress || "";
  return ip === "127.0.0.1" || ip === "::1" || ip === "::ffff:127.0.0.1";
}

app.use((req, res, next) => {
  if (isLocal(req)) return next();
  const cookieTok = (req.headers.cookie || "").split(/;\s*/).find(c => c.startsWith("sf_t="));
  if (cookieTok && cookieTok.slice(5) === cfg.token) return next();
  if (req.query.t === cfg.token) {
    res.setHeader("Set-Cookie", `sf_t=${cfg.token}; Path=/; Max-Age=31536000; SameSite=Lax`);
    return next();
  }
  res.status(403).send("需要访问口令。请用启动窗口里显示的完整网址（带 ?t=）打开一次。");
});

app.use(express.static(path.join(__dirname, "public")));

// ---------------------------------------------------------------------------
// Reader API
// ---------------------------------------------------------------------------

// Resolve a vault-relative path and refuse anything that escapes the vault.
function safeVaultPath(rel) {
  const abs = path.resolve(VAULT, rel);
  if (abs !== VAULT && !abs.startsWith(VAULT + path.sep)) return null;
  return abs;
}

function listMd(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter(e => e.isFile() && e.name.endsWith(".md"))
      .map(e => e.name)
      .sort();
  } catch { return []; }
}

app.get("/api/books", (_req, res) => {
  let books = [];
  try {
    books = fs.readdirSync(LIBRARY, { withFileTypes: true })
      .filter(e => e.isDirectory())
      .map(e => {
        const dir = path.join(LIBRARY, e.name);
        const chapters = listMd(path.join(dir, "00-原书"));
        const translated = listMd(path.join(dir, "译文"));
        return {
          name: e.name,
          chapters: chapters.length,
          translated: translated.length,
          hasOutline: fs.existsSync(path.join(dir, "01-全书梗概.md")),
        };
      });
  } catch { /* Library may be empty */ }
  res.json({ books });
});

app.get("/api/book", (req, res) => {
  const name = String(req.query.name || "");
  const dir = safeVaultPath(path.join("Library", name));
  if (!dir || !fs.existsSync(dir)) return res.status(404).json({ error: "no_such_book" });
  res.json({
    name,
    outline: fs.existsSync(path.join(dir, "01-全书梗概.md")),
    summary: fs.existsSync(path.join(dir, "02-逐章摘要.md")),
    original: listMd(path.join(dir, "00-原书")),
    translated: listMd(path.join(dir, "译文")),
    notes: listMd(path.join(dir, "笔记")),
    discussions: listMd(path.join(dir, "讨论")),
  });
});

app.get("/api/file", (req, res) => {
  const rel = String(req.query.path || "");
  const abs = safeVaultPath(rel);
  if (!abs || !abs.endsWith(".md") || !fs.existsSync(abs)) {
    return res.status(404).json({ error: "no_such_file" });
  }
  const md = fs.readFileSync(abs, "utf8");
  // Obsidian-style [[links]] become plain emphasized text in the reader —
  // navigation happens through the chapter list, not wiki links.
  const cleaned = md.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, target, label) => label || target.split("/").pop());
  res.json({ path: rel, html: marked.parse(cleaned) });
});

// ---------------------------------------------------------------------------
// Chat API — SSE stream wrapping `claude -p`
// ---------------------------------------------------------------------------

// Only one chat job at a time: the underlying conversation is shared, and two
// concurrent `claude --continue` runs would race on it.
let chatBusy = false;

const TOOL_LABELS = {
  Read: "读文件", Write: "写文件", Edit: "改文件", Bash: "处理文件",
  Glob: "找文件", Grep: "搜内容", WebSearch: "联网搜索", WebFetch: "查网页",
  Task: "调用助手", TodoWrite: "整理清单",
};

app.post("/api/chat", (req, res) => {
  const message = String((req.body && req.body.message) || "").trim();
  if (!message) return res.status(400).json({ error: "empty" });
  if (chatBusy) return res.status(429).json({ error: "busy", hint: "上一条还在处理，稍等它做完。" });
  chatBusy = true;

  res.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-store",
    "Connection": "keep-alive",
    "X-Accel-Buffering": "no",
  });
  const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);

  // The message rides in argv, not stdin: claude's stdin decoding on Windows
  // follows the local codepage, which turns UTF-8 Chinese into mojibake
  // (verified live), while argv arrives via the Unicode CreateProcess path
  // intact. But argv + shell:true means cmd.exe re-parses the line, and its
  // quoting is not injection-safe (CVE-2024-27980). Since the message is prose
  // for an LLM, we neutralise every character cmd treats specially by swapping
  // it for its fullwidth twin — visually identical to the model, inert to cmd.
  // Newlines become spaces (a bare newline would terminate the cmd command).
  const CMD_META = { '"': "＂", "%": "％", "&": "＆", "|": "｜", "<": "＜", ">": "＞", "^": "＾", "(": "（", ")": "）", "!": "！" };
  const safeMessage = process.platform === "win32"
    ? message.replace(/["%&|<>^()!]/g, c => CMD_META[c]).replace(/\r?\n/g, " ")
    : message;
  const args = ["-p", safeMessage, "--output-format", "stream-json", "--verbose",
    "--include-partial-messages", "--dangerously-skip-permissions"];
  if (fs.existsSync(SESSION_FLAG)) args.splice(1, 0, "--continue");

  const child = spawn(process.platform === "win32" ? "claude.cmd" : "claude", args, {
    cwd: VAULT,
    env: { ...process.env, ...cfg.env },
    shell: process.platform === "win32",
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],   // no stdin: skips claude's 3s stdin wait
  });

  child.on("error", err => {
    console.error("[chat] spawn failed:", err.message);
    chatBusy = false;
    send("error", { text: "启动助手失败（找不到 claude 命令）。重跑一次安装器应该能修好。" });
    send("done", { ok: false });
    res.end();
  });

  let sawDelta = false;       // partial deltas arrived → skip duplicate full messages
  let stderrTail = "";
  let buffer = "";

  child.stdout.on("data", chunk => {
    buffer += chunk.toString("utf8");
    let nl;
    while ((nl = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      let ev;
      try { ev = JSON.parse(line); } catch { continue; }

      if (ev.type === "stream_event" && ev.event) {
        const e = ev.event;
        if (e.type === "content_block_delta" && e.delta && e.delta.type === "text_delta") {
          sawDelta = true;
          send("delta", { text: e.delta.text });
        }
      } else if (ev.type === "assistant" && ev.message && Array.isArray(ev.message.content)) {
        for (const block of ev.message.content) {
          if (block.type === "text" && !sawDelta) {
            send("delta", { text: block.text });
          } else if (block.type === "tool_use") {
            send("status", { text: TOOL_LABELS[block.name] || "处理中", tool: block.name });
          }
        }
        // A new assistant turn follows tool results — deltas restart with it.
        if (sawDelta) send("turn", {});
      }
      // "result" events are ignored here — the close handler emits the single
      // authoritative "done" so the client never sees it twice.
    }
  });

  child.stderr.on("data", d => { stderrTail = (stderrTail + d.toString("utf8")).slice(-2000); });

  child.on("close", code => {
    chatBusy = false;
    if (code !== 0) console.error(`[chat] claude exited ${code}. stderr tail:\n${stderrTail}`);
    if (code === 0) {
      try { fs.writeFileSync(SESSION_FLAG, String(Date.now())); } catch { }
    } else {
      // First-ever message with --continue and no prior session is the one
      // recoverable failure worth auto-retrying without the flag.
      const noConvo = /no conversation|No conversation found/i.test(stderrTail);
      if (noConvo && fs.existsSync(SESSION_FLAG)) { try { fs.unlinkSync(SESSION_FLAG); } catch { } }
      send("error", {
        text: noConvo
          ? "会话记录对不上了，请把刚才那句再发一次。"
          : "助手没回应。可能是网络或额度问题，稍等重试；一直不行就重启一下「群星阅览室」。",
      });
    }
    send("done", { ok: code === 0 });
    res.end();
  });

  // NOT req.on("close") — since Node 13 that fires as soon as the request body
  // is consumed, which killed the child instantly. res 'close' with
  // writableEnded=false is the real client-disconnect signal.
  res.on("close", () => {
    if (!res.writableEnded) {
      try { child.kill(); } catch { }
      chatBusy = false;
    }
  });
});

app.get("/api/status", (_req, res) => {
  res.json({ busy: chatBusy, vault: VAULT });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

function lanAddress() {
  // Prefer real home-LAN ranges; 172.16-31.x is almost always WSL/Docker/VPN
  // virtual adapters on a home Windows box, so it's the last resort.
  const candidates = [];
  for (const ifaces of Object.values(os.networkInterfaces())) {
    for (const i of ifaces || []) {
      if (i.family === "IPv4" && !i.internal) candidates.push(i.address);
    }
  }
  return candidates.find(a => a.startsWith("192.168."))
    || candidates.find(a => a.startsWith("10."))
    || candidates[0]
    || null;
}

app.listen(cfg.port, "0.0.0.0", () => {
  const lan = lanAddress();
  const lanUrl = lan ? `http://${lan}:${cfg.port}/?t=${cfg.token}` : null;
  console.log("");
  console.log("  ┌──────────────────────────────────────────────┐");
  console.log("  │  群星阅览室已启动 📚                          │");
  console.log("  └──────────────────────────────────────────────┘");
  console.log("");
  console.log(`  电脑上用:  http://localhost:${cfg.port}/`);
  if (lanUrl) {
    console.log(`  手机上用:  ${lanUrl}`);
    console.log("  （手机连同一个 Wi-Fi，扫下面二维码）");
    console.log("");
    qrcode.generate(lanUrl, { small: true });
  }
  console.log("");
  console.log("  这个窗口别关，关了手机和网页就断了。可以最小化。");
});
