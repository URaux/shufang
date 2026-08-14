// sync.js — 群星阅览室的 git 同步引擎（isomorphic-git 封装）。
//
// 职责：给每本书一个本地 git 仓（版本历史），以及与 GitHub 私有仓的静默同步。
// 原则：
//   - 任何失败都不能挡住看书聊天。所有函数返回状态对象，不向业务路径抛异常。
//   - 用户永远不接触 git 词汇。冲突兜底是「远端赢 + 本地备份」，绝不出现
//     conflict marker，同步永不卡死（设计依据 docs/2026-08-15-collab-research.md）。
//   - isomorphic-git 是运行时才可能装上的依赖（老用户自动更新不带 npm install，
//     server.js 启动时自愈补装），所以这里全部惰性加载。

const fs = require("fs");
const path = require("path");

let git = null;
let ghttp = null;

function engineReady() {
  if (git) return true;
  try {
    git = require("isomorphic-git");
    ghttp = require("isomorphic-git/http/node");
    return true;
  } catch {
    return false;
  }
}

const AUTHOR_FALLBACK = "群星阅览室";

function author(name) {
  return { name: name || AUTHOR_FALLBACK, email: "reader@shufang.local" };
}

function onAuthFor(token) {
  // GitHub fine-grained PAT / classic token 都走 HTTP Basic
  return () => ({ username: "x-access-token", password: token });
}

function isRepo(dir) {
  return fs.existsSync(path.join(dir, ".git"));
}

// 书仓的 .gitignore：冲突备份不进仓；系统垃圾不进仓
const GITIGNORE_BASE = ["*.冲突备份-*", ".DS_Store", "Thumbs.db", "desktop.ini", ""].join("\n");

async function ensureGitignore(dir) {
  const p = path.join(dir, ".gitignore");
  let cur = "";
  try { cur = fs.readFileSync(p, "utf8"); } catch { }
  if (!cur.includes("*.冲突备份-*")) {
    fs.writeFileSync(p, (cur ? cur.replace(/\n*$/, "\n") : "") + GITIGNORE_BASE);
  }
}

// 共享前检查：单文件 >50MB 的原始文件自动忽略（GitHub 100MB 硬限之前主动让路）
function ignoreBigFiles(dir) {
  const ignored = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name === ".git") continue;
      const abs = path.join(d, e.name);
      if (e.isDirectory()) walk(abs);
      else if (e.isFile() && fs.statSync(abs).size > 50 * 1024 * 1024) {
        ignored.push(path.relative(dir, abs).split(path.sep).join("/"));
      }
    }
  };
  try { walk(dir); } catch { }
  if (ignored.length) {
    const p = path.join(dir, ".gitignore");
    let cur = "";
    try { cur = fs.readFileSync(p, "utf8"); } catch { }
    const add = ignored.filter(f => !cur.includes(f));
    if (add.length) fs.writeFileSync(p, cur.replace(/\n*$/, "\n") + add.join("\n") + "\n");
  }
  return ignored;
}

async function initRepo(dir, authorName) {
  if (!engineReady()) return { ok: false, error: "engine_missing" };
  try {
    if (!isRepo(dir)) await git.init({ fs, dir, defaultBranch: "master" });
    await ensureGitignore(dir);
    await commitAll(dir, authorName, "建库");
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
}

async function currentBranch(dir) {
  try { return (await git.currentBranch({ fs, dir, fullname: false })) || "master"; }
  catch { return "master"; }
}

// isomorphic-git 的 fetch 需要 remote 配置里有 refspec，光传 url 会抛
// NoRefspecError——本地 init 的仓（发起人路径）没有 origin，这里补上。
// force:true 顺带处理「换了仓库地址」的情况。
async function ensureRemote(dir, url) {
  try {
    const remotes = await git.listRemotes({ fs, dir });
    const origin = remotes.find(r => r.remote === "origin");
    if (!origin || origin.url !== url) {
      await git.addRemote({ fs, dir, remote: "origin", url, force: true });
    }
  } catch {
    await git.addRemote({ fs, dir, remote: "origin", url, force: true }).catch(() => { });
  }
}

// 把工作区所有改动收进一个 commit。没改动返回 { ok:true, committed:false }。
async function commitAll(dir, authorName, message) {
  if (!engineReady()) return { ok: false, error: "engine_missing" };
  try {
    const matrix = await git.statusMatrix({ fs, dir });
    let changed = false;
    for (const [fp, head, work] of matrix) {
      if (head === 1 && work === 1) continue;          // 没动
      changed = true;
      if (work === 0) await git.remove({ fs, dir, filepath: fp });
      else await git.add({ fs, dir, filepath: fp });
    }
    if (!changed) return { ok: true, committed: false };
    const oid = await git.commit({
      fs, dir,
      message: message || "更新",
      author: author(authorName),
    });
    return { ok: true, committed: true, oid };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
}

// base..head 之间改动过的文件清单（不含目录）
async function changedFiles(dir, baseOid, headOid) {
  const out = await git.walk({
    fs, dir,
    trees: [git.TREE({ ref: baseOid }), git.TREE({ ref: headOid })],
    map: async (fp, [a, b]) => {
      if (fp === ".") return undefined;
      const [at, bt] = await Promise.all([a && a.type(), b && b.type()]);
      if (at === "tree" || bt === "tree") return undefined;
      const [ao, bo] = await Promise.all([a && a.oid(), b && b.oid()]);
      return ao !== bo ? fp : undefined;
    },
  });
  return out.filter(Boolean);
}

async function readFileAt(dir, oid, filepath) {
  try {
    const { blob } = await git.readBlob({ fs, dir, oid, filepath });
    return Buffer.from(blob);
  } catch { return null; }   // 该版本里没有这个文件
}

async function setBranchTo(dir, branch, oid) {
  await git.writeRef({ fs, dir, ref: `refs/heads/${branch}`, value: oid, force: true });
  await git.checkout({ fs, dir, ref: branch, force: true });
}

// 完整克隆（加入共享时用）
async function cloneRepo(url, token, destDir) {
  if (!engineReady()) return { ok: false, error: "engine_missing" };
  try {
    fs.mkdirSync(destDir, { recursive: true });
    await git.clone({
      fs, http: ghttp, dir: destDir, url,
      onAuth: onAuthFor(token),
      singleBranch: true,
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e.message || e) };
  }
}

// 一次完整同步：commit 本地 → fetch → 合并（兜底远端赢+备份）→ push（拒了重试）。
// 返回 { ok, pushed, pulled, conflicts: [备份文件名], offline, error }
async function sync(dir, { url, token, authorName }) {
  if (!engineReady()) return { ok: false, error: "engine_missing" };
  const result = { ok: true, pushed: false, pulled: false, conflicts: [], offline: false };
  try {
    await commitAll(dir, authorName);
    const branch = await currentBranch(dir);
    await ensureRemote(dir, url);

    for (let round = 0; round < 3; round++) {
      // ---- fetch ----
      let fetchHead = null;
      try {
        const fr = await git.fetch({
          fs, http: ghttp, dir, url,
          ref: branch, singleBranch: true, tags: false,
          onAuth: onAuthFor(token),
        });
        fetchHead = fr.fetchHead || null;
      } catch (e) {
        const msg = String(e.message || e);
        // 远端还是空仓（第一次推送前）→ 没东西可拉，直接推
        if (!/could not find|empty|404/i.test(msg)) {
          result.offline = true;               // 网络不通：本地照常，静默返回
          return result;
        }
      }

      const localHead = await git.resolveRef({ fs, dir, ref: branch }).catch(() => null);
      if (!localHead) return { ok: false, error: "no_local_commits" };

      if (fetchHead && fetchHead !== localHead) {
        const bases = await git.findMergeBase({ fs, dir, oids: [localHead, fetchHead] }).catch(() => []);
        const base = bases && bases[0];

        if (base === fetchHead) {
          // 我们领先 → 直接推
        } else if (base === localHead) {
          // 远端领先 → 快进
          await setBranchTo(dir, branch, fetchHead);
          result.pulled = true;
        } else {
          // 双方都动了 → 先试正经合并
          await git.writeRef({ fs, dir, ref: `refs/remotes/origin/${branch}`, value: fetchHead, force: true });
          let merged = false;
          try {
            await git.merge({
              fs, dir,
              ours: branch, theirs: `refs/remotes/origin/${branch}`,
              abortOnConflict: true,
              author: author(authorName),
            });
            await git.checkout({ fs, dir, ref: branch, force: true });
            merged = true;
            result.pulled = true;
          } catch {
            merged = false;
          }

          if (!merged) {
            // 兜底：远端赢 + 本地备份。
            // 本地相对 base 改过的文件先留内容；重置到远端后，
            // 没跟远端撞车的原样放回，撞车的写成 *.冲突备份-* 文件。
            const localChanged = base ? await changedFiles(dir, base, localHead) : [];
            const remoteChanged = base ? await changedFiles(dir, base, fetchHead) : [];
            const remoteSet = new Set(remoteChanged);
            const saved = new Map();
            for (const fp of localChanged) {
              const content = await readFileAt(dir, localHead, fp);
              if (content !== null) saved.set(fp, content);
            }
            await setBranchTo(dir, branch, fetchHead);
            const stamp = new Date().toISOString().slice(0, 10);
            for (const [fp, content] of saved) {
              const abs = path.join(dir, ...fp.split("/"));
              fs.mkdirSync(path.dirname(abs), { recursive: true });
              if (remoteSet.has(fp)) {
                const backup = abs.replace(/(\.[^.\\/]+)?$/, m => `.冲突备份-${stamp}${m || ""}`);
                fs.writeFileSync(backup, content);
                result.conflicts.push(path.basename(backup));
              } else {
                fs.writeFileSync(abs, content);
              }
            }
            await commitAll(dir, authorName, "合并远端更新");
            result.pulled = true;
          }
        }
      }

      // ---- push ----
      try {
        const pr = await git.push({
          fs, http: ghttp, dir, url,
          ref: branch, remoteRef: `refs/heads/${branch}`,
          onAuth: onAuthFor(token),
        });
        if (pr && pr.ok === false) throw new Error(JSON.stringify(pr.errors || pr));
        result.pushed = true;
        return result;
      } catch (e) {
        const msg = String(e.message || e);
        if (/not a simple fast-forward|rejected|failed to update/i.test(msg)) {
          continue;                            // 远端又更新了 → 下一轮再拉再推
        }
        if (/401|403|Unauthorized|credential/i.test(msg)) {
          return { ...result, ok: false, error: "auth" };
        }
        result.offline = true;                 // 其它网络类失败：视为离线
        return result;
      }
    }
    return { ...result, ok: false, error: "push_retries_exhausted" };
  } catch (e) {
    return { ok: false, pushed: false, pulled: false, conflicts: [], offline: false, error: String(e.message || e) };
  }
}

// 仅探测远端是否有新东西（轮询用，不改本地）
async function remoteAhead(dir, { url, token }) {
  if (!engineReady()) return { ok: false, error: "engine_missing" };
  try {
    const branch = await currentBranch(dir);
    await ensureRemote(dir, url);
    const fr = await git.fetch({
      fs, http: ghttp, dir, url, ref: branch, singleBranch: true, tags: false,
      onAuth: onAuthFor(token),
    });
    const localHead = await git.resolveRef({ fs, dir, ref: branch }).catch(() => null);
    return { ok: true, ahead: !!(fr.fetchHead && fr.fetchHead !== localHead) };
  } catch {
    return { ok: false, offline: true };
  }
}

module.exports = {
  engineReady, isRepo, initRepo, commitAll, cloneRepo, sync, remoteAhead, ignoreBigFiles,
};
