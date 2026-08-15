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
const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { marked } = require("marked");
const qrcode = require("qrcode-terminal");

// ---------------------------------------------------------------------------
// 依赖自愈：老用户的启动器只在 node_modules 不存在时才 npm install，自动更新
// 又只搬旧 node_modules——所以新加的依赖（isomorphic-git）到不了他们机器上。
// 这里探测缺包就当场补装一次；补不上只是协作功能不可用，看书聊天照常。
// ---------------------------------------------------------------------------
(function healDeps() {
  try { require.resolve("isomorphic-git"); return; } catch { }
  console.log("[群星阅览室] 正在安装协作组件（第一次要半分钟左右）...");
  try {
    spawnSync(process.platform === "win32" ? "npm.cmd" : "npm",
      ["install", "--omit=dev", "--silent"],
      { cwd: __dirname, stdio: "inherit", shell: process.platform === "win32", timeout: 300000 });
  } catch { }
  try { require.resolve("isomorphic-git"); }
  catch { console.log("[群星阅览室] 协作组件没装上（可能没网）。不影响看书聊天，下次启动会再试。"); }
})();

const gitSync = require("./sync");
const collab = require("./collab");

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

// dsh 模式的轻量会话记忆：一行一条 {t:"user"|"bot", x:"..."}，存 vault 根。
// claude 模式用自己的 --continue，不碰这个文件。
const CHAT_LOG = path.join(VAULT, ".shufang-chat.jsonl");

function appendChat(role, text) {
  try {
    fs.appendFileSync(CHAT_LOG, JSON.stringify({ t: role, x: String(text).slice(0, 4000) }) + "\n");
  } catch { }
}

function readChatHistory(turns) {
  try {
    const lines = fs.readFileSync(CHAT_LOG, "utf8").trim().split("\n");
    return lines.slice(-turns * 2).map(l => {
      try {
        const { t, x } = JSON.parse(l);
        return (t === "user" ? "用户：" : "助手：") + x;
      } catch { return ""; }
    }).filter(Boolean).join("\n");
  } catch { return ""; }
}

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
  // 立刻把响应头推出去：dsh 模式在完成前没有任何 body 写入，
  // 不冲的话头会一直攒在缓冲里，客户端等 5 分钟就 headers timeout。
  if (typeof res.flushHeaders === "function") res.flushHeaders();
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
  const sanitize = (s) => process.platform === "win32"
    ? s.replace(/["%&|<>^()!]/g, c => CMD_META[c]).replace(/\r?\n/g, " ")
    : s;

  // 大脑可切换：claude（Claude Code CLI，默认）或 dsh（DeepSeek Harness）。
  // dsh 的 headless 是单发无续接，会话记忆靠把最近几轮对话拼进任务文本
  //（真实状态本来就在 vault 文件里，这层只是让"刚才说的那本"能接得上）。
  const brain = cfg.brain === "dsh" ? "dsh" : "claude";
  let child;
  if (brain === "dsh") {
    const history = readChatHistory(6);
    const task = history
      ? `【此前对话，供衔接语境】\n${history}\n【本轮用户消息】\n${message}`
      : message;
    // DeepSeek key：dsh 读 DEEPSEEK_API_KEY；沿用配置里已有的 sk- key（同一把）
    const dskey = cfg.env.DEEPSEEK_API_KEY || cfg.env.ANTHROPIC_AUTH_TOKEN || "";
    const dshArgs = ["--profile", "headless"];
    if (fs.existsSync(path.join(__dirname, "dsh-model.yml"))) {
      dshArgs.push("--patch", path.join(__dirname, "dsh-model.yml"));
    }
    dshArgs.push(sanitize(task));
    child = spawn(process.platform === "win32" ? "dsh.cmd" : "dsh", dshArgs, {
      cwd: VAULT,
      env: {
        ...process.env,
        DEEPSEEK_API_KEY: dskey,
        DSH_PERMISSION_MODE: "danger-full-access",   // 等价 --dangerously-skip-permissions
        DSH_TELEMETRY_MODE: "DISABLED",
      },
      shell: process.platform === "win32",
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } else {
    const args = ["-p", sanitize(message), "--output-format", "stream-json", "--verbose",
      "--include-partial-messages", "--dangerously-skip-permissions"];
    if (fs.existsSync(SESSION_FLAG)) args.splice(1, 0, "--continue");
    child = spawn(process.platform === "win32" ? "claude.cmd" : "claude", args, {
      cwd: VAULT,
      env: { ...process.env, ...cfg.env },
      shell: process.platform === "win32",
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],   // no stdin: skips claude's 3s stdin wait
    });
  }

  child.on("error", err => {
    console.error("[chat] spawn failed:", err.message);
    chatBusy = false;
    send("error", { text: `启动助手失败（找不到 ${brain} 命令）。重跑一次安装器应该能修好。` });
    send("done", { ok: false });
    res.end();
  });

  let sawDelta = false;       // partial deltas arrived → skip duplicate full messages
  let stderrTail = "";
  let buffer = "";
  let dshOut = "";            // dsh 模式：stdout 是纯文本最终答案，攒起来一次发

  // dsh 干长活（翻一整章十几分钟）时全程无输出——每 15 秒发一个心跳
  // status，既防代理/客户端超时，也让用户知道它还活着。
  let heartbeat = null;
  if (brain === "dsh") {
    let beats = 0;
    heartbeat = setInterval(() => {
      beats++;
      send("status", { text: beats < 3 ? "处理中" : `还在干活（已 ${Math.round(beats * 15 / 60)} 分钟，翻整章会比较久）`, tool: "dsh" });
    }, 15000);
  }

  child.stdout.on("data", chunk => {
    if (brain === "dsh") { dshOut += chunk.toString("utf8"); return; }
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
    if (heartbeat) { clearInterval(heartbeat); heartbeat = null; }
    if (code !== 0) console.error(`[chat] ${brain} exited ${code}. stderr tail:\n${stderrTail}`);
    if (code === 0) {
      if (brain === "dsh") {
        const reply = dshOut.trim();
        send("delta", { text: reply || "（助手没有输出内容）" });
        appendChat("user", message);
        if (reply) appendChat("bot", reply);
      } else {
        try { fs.writeFileSync(SESSION_FLAG, String(Date.now())); } catch { }
      }
      // 大脑可能改了译文/笔记——共享书跟着同步一轮（静默）
      syncAllShared({ quiet: true });
    } else if (brain === "dsh") {
      send("error", { text: "助手没回应。可能是网络或额度问题，稍等重试；一直不行就重启一下「群星阅览室」。" });
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
      if (heartbeat) { clearInterval(heartbeat); heartbeat = null; }
      try { child.kill(); } catch { }
      chatBusy = false;
    }
  });
});

app.get("/api/status", (_req, res) => {
  res.json({ busy: chatBusy, vault: VAULT });
});

// ---------------------------------------------------------------------------
// 协作 API —— 设计见 docs/2026-08-15-collab-research.md
// 配置存 ~/.shufang/config.json：
//   "author": "小王",                     // 本机署名（全局一个）
//   "collab": { "<书名>": { "url": "...", "token": "...", "role": "owner"|"member" } }
// token 绝不进 vault（vault 会被同步出去）。
// ---------------------------------------------------------------------------

function saveConfig() {
  try {
    fs.mkdirSync(CONFIG_DIR, { recursive: true });
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2));
  } catch { }
}

function bookDirOf(name) {
  const dir = safeVaultPath(path.join("Library", name));
  return dir && fs.existsSync(dir) ? dir : null;
}

function collabOf(name) { return (cfg.collab || {})[name] || null; }

// 每本书的同步状态点：green=已同步 yellow=有待上传 gray=离线/出错
const syncState = {};          // book -> { dot, last, conflicts: [] }
const syncing = new Set();     // 防止同一本书并发同步

async function syncBook(name, { quiet } = {}) {
  const remote = collabOf(name);
  const dir = bookDirOf(name);
  if (!remote || !dir || syncing.has(name)) return;
  syncing.add(name);
  try {
    const r = await gitSync.sync(dir, { url: remote.url, token: remote.token, authorName: cfg.author });
    syncState[name] = {
      dot: r.ok && !r.offline ? "green" : (r.error === "auth" ? "auth" : "gray"),
      last: Date.now(),
      conflicts: r.conflicts || [],
    };
    if (!quiet && r.conflicts && r.conflicts.length) {
      console.log(`[协作] 《${name}》有同时改动，远端版本先生效，你的版本备份在: ${r.conflicts.join(", ")}`);
    }
  } finally {
    syncing.delete(name);
  }
}

function syncAllShared(opts) {
  for (const name of Object.keys(cfg.collab || {})) syncBook(name, opts).catch(() => { });
}

// 状态 + 建议列表（前端侧栏用，轮询友好）
app.get("/api/collab/state", (req, res) => {
  const name = String(req.query.book || "");
  const dir = bookDirOf(name);
  if (!dir) return res.status(404).json({ error: "no_such_book" });
  const remote = collabOf(name);
  const suggestions = collab.listSuggestions(dir);   // 纯文件读取，不依赖 git 引擎
  res.json({
    shared: !!remote,
    role: remote ? remote.role : null,
    author: cfg.author || null,
    engine: gitSync.engineReady(),
    state: syncState[name] || null,
    suggestions,
  });
});

app.post("/api/collab/author", (req, res) => {
  const name = String((req.body && req.body.author) || "").trim().slice(0, 24);
  if (!name) return res.status(400).json({ error: "empty" });
  cfg.author = name;
  saveConfig();
  res.json({ ok: true, author: name });
});

// 发起共享：仓库地址 + token 已由向导引导用户拿到，这里完成初始化 + 首推 + 出邀请串
app.post("/api/collab/share", async (req, res) => {
  const { book, repoUrl, token } = req.body || {};
  const dir = bookDirOf(String(book || ""));
  if (!dir) return res.status(404).json({ error: "no_such_book" });
  if (!gitSync.engineReady()) return res.status(503).json({ error: "engine_missing", hint: "协作组件没装上，重启一次试试。" });
  if (!repoUrl || !token) return res.status(400).json({ error: "missing_fields" });
  const url = String(repoUrl).trim().replace(/\.git$/, "") + ".git";

  // 版权书不进公开仓——这条是硬规则，确认不了就不放行（fail-closed）
  const check = await collab.checkRepoPrivate(url, String(token).trim());
  if (!check.ok) {
    return res.status(400).json({ error: "verify_failed", hint: "没能确认仓库是私密的（网络不通或钥匙权限不够）。稍后再试；建仓时记得选 Private。" });
  }
  if (!check.private) {
    return res.status(400).json({ error: "repo_public", hint: "这个仓库是公开的。书的内容不能进公开仓库——去 GitHub 仓库 Settings 把它改成 Private，或者重建一个 Private 仓。" });
  }

  const ignored = gitSync.ignoreBigFiles(dir);
  const init = await gitSync.initRepo(dir, cfg.author);
  if (!init.ok) return res.status(500).json({ error: init.error });

  cfg.collab = cfg.collab || {};
  cfg.collab[book] = { url, token: String(token).trim(), role: "owner" };
  saveConfig();

  await syncBook(book, { quiet: true });
  const st = syncState[book] || {};
  if (st.dot === "auth") {
    delete cfg.collab[book]; saveConfig();
    return res.status(400).json({ error: "auth", hint: "GitHub 不认这把钥匙。检查 token 是不是复制全了、是不是给了这个仓库的 Contents 读写权限。" });
  }
  res.json({
    ok: true,
    invite: collab.makeInvite({ url, token: cfg.collab[book].token, book }),
    ignoredBigFiles: ignored,
  });
});

// 重新出示邀请串（发起人）
app.get("/api/collab/invite", (req, res) => {
  const name = String(req.query.book || "");
  const remote = collabOf(name);
  if (!remote) return res.status(404).json({ error: "not_shared" });
  res.json({ invite: collab.makeInvite({ url: remote.url, token: remote.token, book: name }) });
});

// 加入共享：粘贴邀请串 → 克隆到书架
app.post("/api/collab/join", async (req, res) => {
  const invite = collab.parseInvite((req.body || {}).invite);
  if (!invite) return res.status(400).json({ error: "bad_invite", hint: "邀请串不完整，让发起人重新发一次（以 SF1: 开头的一整串）。" });
  if (!gitSync.engineReady()) return res.status(503).json({ error: "engine_missing" });
  const dest = safeVaultPath(path.join("Library", invite.book));
  if (!dest) return res.status(400).json({ error: "bad_book_name" });
  if (fs.existsSync(dest)) return res.status(409).json({ error: "book_exists", hint: `书架上已经有《${invite.book}》了。` });

  const r = await gitSync.cloneRepo(invite.url, invite.token, dest);
  if (!r.ok) {
    try { fs.rmSync(dest, { recursive: true, force: true }); } catch { }
    const authFail = /401|403|Unauthorized/i.test(r.error || "");
    return res.status(400).json({
      error: authFail ? "auth" : "clone_failed",
      hint: authFail ? "钥匙不对或已被撤销，找发起人要个新邀请串。" : "下载失败，检查网络后再试一次。",
    });
  }
  cfg.collab = cfg.collab || {};
  cfg.collab[invite.book] = { url: invite.url, token: invite.token, role: "member" };
  saveConfig();
  res.json({ ok: true, book: invite.book });
});

// 提建议
app.post("/api/collab/suggest", (req, res) => {
  const { book, chapter, anchor, anchorIndex, proposed, reason } = req.body || {};
  const dir = bookDirOf(String(book || ""));
  if (!dir) return res.status(404).json({ error: "no_such_book" });
  if (!cfg.author) return res.status(400).json({ error: "no_author", hint: "先填一个署名。" });
  const r = collab.createSuggestion(dir, {
    chapter, anchor, anchorIndex, proposed, reason, author: cfg.author,
  });
  if (!r.ok) return res.status(400).json(r);
  syncBook(String(book), { quiet: true }).catch(() => { });
  res.json(r);
});

// 附议
app.post("/api/collab/second", (req, res) => {
  const { book, id } = req.body || {};
  const dir = bookDirOf(String(book || ""));
  if (!dir) return res.status(404).json({ error: "no_such_book" });
  const r = collab.secondSuggestion(dir, String(id || ""), cfg.author);
  if (!r.ok) return res.status(400).json(r);
  syncBook(String(book), { quiet: true }).catch(() => { });
  res.json(r);
});

// 拍板：accept / reject（UI 只对 owner 显示按钮；这里不做强制——共享 token 模型下
// 服务端强制没有意义，防的是误触不是恶意，见研究文档问题六）
app.post("/api/collab/decide", (req, res) => {
  const { book, id, action } = req.body || {};
  const dir = bookDirOf(String(book || ""));
  if (!dir) return res.status(404).json({ error: "no_such_book" });
  const r = collab.decideSuggestion(dir, String(id || ""), String(action || ""), cfg.author);
  if (!r.ok) return res.status(400).json(r);
  syncBook(String(book), { quiet: true }).catch(() => { });
  res.json(r);
});

// 手动触发同步（前端「立即同步」）
app.post("/api/collab/sync", async (req, res) => {
  const name = String((req.body || {}).book || "");
  if (!collabOf(name)) return res.status(404).json({ error: "not_shared" });
  await syncBook(name);
  res.json({ ok: true, state: syncState[name] || null });
});

// 启动时拉一次 + 每 2 分钟一轮（静默，失败照常）
setTimeout(() => syncAllShared({ quiet: true }), 3000);
setInterval(() => syncAllShared({ quiet: true }), 120000);

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
