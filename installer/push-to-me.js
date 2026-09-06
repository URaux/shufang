// 把手上这一版直接装到本机那份上，不经过发布。
//
//   node installer/push-to-me.js
//
// 为什么要它：本机装的那份（~/.shufang/app）是自动更新器从**分发仓**拉的，
// 所以在我这边写完代码，车主要看到得等一次正式发布。可开发中途想看进度是常事，
// 而每加个功能就往分发仓推一次，等于把没做完的东西发给所有装了的人。
//
// 这个脚本走的是另一条路：产物直接盖到本机，不动分发仓。
//
// 关键那一步是 .app-sha —— 更新器拿它跟分发仓 master 的 sha 比，不一样就重下。
// 这里把**当前分发仓的 sha**写进去，更新器就认为已是最新、不来碰这份开发版；
// 等真正发布时分发仓 sha 变了，它自然会把正式版拉下来盖掉。
// 不写的话，下次启动就被"更新"回旧的正式版，白装。

"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "dist-build");
const HOME = process.env.SHUFANG_HOME || path.join(os.homedir(), ".shufang");
const APP = path.join(HOME, "app");
const SHA = path.join(HOME, ".app-sha");

const die = m => { console.error("\n[X] " + m); process.exit(1); };
const ok = m => console.log("   OK: " + m);

if (!fs.existsSync(OUT)) die("还没构建。先跑 node installer/build-dist.js");
if (!fs.existsSync(path.join(OUT, "webapp", "server.js"))) die("dist-build 里没有 webapp/server.js，构建没成？");
if (!fs.existsSync(APP)) die(`本机没装（找不到 ${APP}）。这个脚本只负责更新已经装好的那份。`);

// 服务正跑着的话，Windows 上文件可能被占；先探一下，占着就让人先关
const port = (() => {
  try { return JSON.parse(fs.readFileSync(path.join(HOME, "config.json"), "utf8")).port || 7787; }
  catch { return 7787; }
})();

(async () => {
  let live = false;
  try {
    const r = await fetch(`http://127.0.0.1:${port}/api/status`, { signal: AbortSignal.timeout(1500) });
    live = r.ok;
  } catch { }
  if (live) {
    console.log(`\n[!] ${port} 上还跑着一个，先把它关掉再跑这个脚本`);
    console.log("    （任务栏图标右键退出，或者结束 node 进程）");
    process.exit(2);
  }

  console.log(`\n>> 装到 ${APP}`);
  // 整目录替换而不是覆盖：覆盖会把上一版多出来的文件留在原地，
  // 旧文件混在新版本里是最难查的那类问题。留一份 app.old 兜底。
  const backup = path.join(HOME, "app.old");
  fs.rmSync(backup, { recursive: true, force: true });
  fs.renameSync(APP, backup);
  try {
    fs.cpSync(OUT, APP, { recursive: true });
    // node_modules 是装机时装的，产物里没有，从旧的搬过来
    const oldMods = path.join(backup, "webapp", "node_modules");
    const newMods = path.join(APP, "webapp", "node_modules");
    if (fs.existsSync(oldMods) && !fs.existsSync(newMods)) fs.renameSync(oldMods, newMods);
  } catch (e) {
    fs.rmSync(APP, { recursive: true, force: true });
    fs.renameSync(backup, APP);
    die("装的时候出错，已经还原成原来那份：" + e.message);
  }
  ok("文件换好了（原来那份在 app.old）");

  // 记上分发仓当前的 sha，免得下次启动被更新器盖回正式版
  let sha = "";
  try {
    sha = execFileSync("git", ["rev-parse", "dist/master"], { cwd: ROOT, encoding: "utf8" }).trim();
  } catch { }
  if (/^[0-9a-f]{40}$/.test(sha)) {
    fs.writeFileSync(SHA, sha, "utf8");
    ok(`.app-sha 记成 ${sha.slice(0, 7)}（更新器不会来盖这份开发版）`);
  } else {
    console.log("   !! 拿不到 dist/master 的 sha，.app-sha 没改——下次启动可能被更新器盖回正式版");
  }

  const n = fs.readFileSync(path.join(APP, "webapp", "server.js"), "utf8").length;
  console.log(`\n   装好了。server.js ${(n / 1024 / 1024).toFixed(1)} MB`);
  console.log("   用 ~/.shufang/启动.vbs 打开就是这一版。");
})();
