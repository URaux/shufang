// collab.js — 多人校对协作：建议文件的读写、采纳落盘、邀请串。
//
// 数据模型（docs/2026-08-15-collab-research.md 问题三）：
//   Library/<书名>/校对/<章节名>/<id>.md    一条建议一个文件，新增文件永不冲突
//   frontmatter: id/chapter/anchor/anchor_index/proposed/reason/author/created/status
//   status: open / accepted / rejected / stale
//
// 译文只有「采纳」动作改，且是确定性字符串替换——不走 LLM。

const fs = require("fs");
const path = require("path");

// ---------------------------------------------------------------------------
// frontmatter：写的时候所有字符串值都 JSON 编码（JSON 字符串是合法 YAML 标量，
// 引号、换行、冒号都不会破格式）；读的时候 JSON.parse 失败就取原文。
// ---------------------------------------------------------------------------

function fmEncode(obj) {
  const lines = ["---"];
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    lines.push(`${k}: ${typeof v === "string" ? JSON.stringify(v) : v}`);
  }
  lines.push("---");
  return lines.join("\n");
}

function fmParse(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { meta: {}, body: text };
  const meta = {};
  for (const line of m[1].split(/\r?\n/)) {
    const i = line.indexOf(":");
    if (i < 0) continue;
    const k = line.slice(0, i).trim();
    let v = line.slice(i + 1).trim();
    if (v.startsWith('"')) { try { v = JSON.parse(v); } catch { } }
    else if (/^\d+$/.test(v)) v = Number(v);
    meta[k] = v;
  }
  return { meta, body: m[2] || "" };
}

// ---------------------------------------------------------------------------
// 建议 CRUD
// ---------------------------------------------------------------------------

const REVIEW_DIR = "校对";

function reviewRoot(bookDir) { return path.join(bookDir, REVIEW_DIR); }

function sanitizeName(s) {
  return String(s || "").replace(/[\\/:*?"<>|\s]/g, "").slice(0, 24) || "匿名";
}

function newId(authorName) {
  const d = new Date();
  const pad = n => String(n).padStart(2, "0");
  const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`;
  const rand = Math.random().toString(16).slice(2, 6);
  return `${stamp}-${sanitizeName(authorName)}-${rand}`;
}

function listSuggestions(bookDir) {
  const root = reviewRoot(bookDir);
  const out = [];
  let chapters = [];
  try { chapters = fs.readdirSync(root, { withFileTypes: true }).filter(e => e.isDirectory()); } catch { return out; }
  for (const ch of chapters) {
    const dir = path.join(root, ch.name);
    let files = [];
    try { files = fs.readdirSync(dir).filter(f => f.endsWith(".md") && !f.includes(".冲突备份-")); } catch { continue; }
    for (const f of files) {
      try {
        const { meta, body } = fmParse(fs.readFileSync(path.join(dir, f), "utf8"));
        if (!meta.id) continue;
        out.push({ ...meta, body: body.trim(), _file: [REVIEW_DIR, ch.name, f].join("/") });
      } catch { }
    }
  }
  // open 在前，新的在前
  out.sort((a, b) => (a.status === "open" ? 0 : 1) - (b.status === "open" ? 0 : 1) || String(b.created).localeCompare(String(a.created)));
  return out;
}

function suggestionPath(bookDir, id) {
  for (const s of listSuggestions(bookDir)) {
    if (s.id === id) return path.join(bookDir, s._file);
  }
  return null;
}

function createSuggestion(bookDir, { chapter, anchor, anchorIndex, proposed, reason, author }) {
  if (!chapter || !anchor) return { ok: false, error: "missing_fields" };
  if (!proposed && !reason) return { ok: false, error: "need_proposed_or_reason" };
  const chapterAbs = path.join(bookDir, ...chapter.split("/"));
  if (!fs.existsSync(chapterAbs)) return { ok: false, error: "no_such_chapter" };

  const id = newId(author);
  const chapterSlug = path.basename(chapter).replace(/\.md$/, "");
  const dir = path.join(reviewRoot(bookDir), chapterSlug);
  fs.mkdirSync(dir, { recursive: true });

  const meta = {
    id, chapter,
    anchor: String(anchor),
    anchor_index: Number(anchorIndex) || 0,
    proposed: proposed ? String(proposed) : "",
    reason: reason ? String(reason) : "",
    author: String(author || "匿名"),
    created: new Date().toISOString(),
    status: "open",
  };
  fs.writeFileSync(path.join(dir, `${id}.md`), fmEncode(meta) + "\n");
  return { ok: true, id };
}

function secondSuggestion(bookDir, id, author) {
  const p = suggestionPath(bookDir, id);
  if (!p) return { ok: false, error: "no_such_suggestion" };
  const text = fs.readFileSync(p, "utf8");
  const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
  fs.writeFileSync(p, text.replace(/\n*$/, "\n") + `- 附议：${author || "匿名"}（${stamp}）\n`);
  return { ok: true };
}

// 找第 n 处出现（n 从 0 数）。返回 -1 = 没有。
function nthIndexOf(hay, needle, n) {
  let i = -1;
  for (let k = 0; k <= n; k++) {
    i = hay.indexOf(needle, i + 1);
    if (i < 0) return -1;
  }
  return i;
}

function countOccurrences(hay, needle) {
  let c = 0, i = -1;
  while ((i = hay.indexOf(needle, i + 1)) >= 0) c++;
  return c;
}

// 采纳 / 拒绝。采纳 = 在译文里做第 anchor_index 处的精确字符串替换。
// 锚点找不到（译文已被改）→ 标 stale，不动译文。
function decideSuggestion(bookDir, id, action, decider) {
  const p = suggestionPath(bookDir, id);
  if (!p) return { ok: false, error: "no_such_suggestion" };
  const { meta, body } = fmParse(fs.readFileSync(p, "utf8"));
  if (meta.status !== "open") return { ok: false, error: "already_decided", status: meta.status };

  const write = (status) => {
    const next = { ...meta, status, decided_by: decider || "", decided_at: new Date().toISOString() };
    fs.writeFileSync(p, fmEncode(next) + "\n" + (body ? body.replace(/\n*$/, "\n") : ""));
  };

  if (action === "reject") { write("rejected"); return { ok: true, status: "rejected" }; }
  if (action !== "accept") return { ok: false, error: "bad_action" };

  if (!meta.proposed) {
    // 只有理由没有改稿的建议没法机械采纳——这是提问，得人来改
    return { ok: false, error: "no_proposed_text" };
  }
  const chapterAbs = path.join(bookDir, ...String(meta.chapter).split("/"));
  let content;
  try { content = fs.readFileSync(chapterAbs, "utf8"); } catch { return { ok: false, error: "chapter_missing" }; }

  const total = countOccurrences(content, meta.anchor);
  if (total === 0) { write("stale"); return { ok: true, status: "stale" }; }
  const idx = nthIndexOf(content, meta.anchor, Math.min(meta.anchor_index || 0, total - 1));
  const updated = content.slice(0, idx) + meta.proposed + content.slice(idx + meta.anchor.length);
  fs.writeFileSync(chapterAbs, updated);
  write("accepted");
  return { ok: true, status: "accepted" };
}

// ---------------------------------------------------------------------------
// 邀请串：SF1:<base64url(JSON)>
// ---------------------------------------------------------------------------

function makeInvite({ url, token, book }) {
  const payload = Buffer.from(JSON.stringify({ u: url, t: token, b: book }), "utf8")
    .toString("base64url");
  return `SF1:${payload}`;
}

function parseInvite(str) {
  const m = String(str || "").trim().match(/^SF1:([A-Za-z0-9_-]+)$/);
  if (!m) return null;
  try {
    const { u, t, b } = JSON.parse(Buffer.from(m[1], "base64url").toString("utf8"));
    if (!u || !t || !b) return null;
    return { url: u, token: t, book: b };
  } catch { return null; }
}

// 校验远端仓库确实是私有的（版权书不进公开仓是硬规则）
async function checkRepoPrivate(url, token) {
  const m = String(url).match(/github\.com\/([^/]+)\/([^/.]+)/);
  if (!m) return { ok: false, error: "not_github" };
  try {
    const r = await fetch(`https://api.github.com/repos/${m[1]}/${m[2]}`, {
      headers: { Authorization: `Bearer ${token}`, "User-Agent": "shufang", Accept: "application/vnd.github+json" },
    });
    if (r.status === 404) return { ok: false, error: "repo_not_found_or_no_access" };
    if (!r.ok) return { ok: false, error: `github_${r.status}` };
    const j = await r.json();
    return { ok: true, private: !!j.private, defaultBranch: j.default_branch };
  } catch {
    return { ok: false, error: "offline" };
  }
}

module.exports = {
  listSuggestions, createSuggestion, secondSuggestion, decideSuggestion,
  makeInvite, parseInvite, checkRepoPrivate, fmParse, countOccurrences,
};
