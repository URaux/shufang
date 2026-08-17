#!/bin/bash
# 在 Mac 上打「群星回廊」全量包。
#
# 用法（在任意空目录里）：
#   curl -fsSL https://raw.githubusercontent.com/URaux/shufang/master/installer/build-mac-bundle.sh -o build.sh
#   bash build.sh
#
# 打出来的是 群星回廊-Mac.zip，可以直接发给别人。
# 这台机器上不需要预装任何东西——Node 和 Pandoc 都由脚本下载后装进包里。
#
# 为什么要在 Mac 上打：包里得放 macOS 版的 Node 和 Pandoc 二进制，
# 而且 zip 里必须保留 unix 执行位，Windows 那边的打包工具做不到这两件事。
set -euo pipefail

NODE_MIN_MAJOR=22
NODE_MIN_MINOR=15      # dsh 的会话存储要 Node 22.15 才有的 zlib zstd 接口

say()  { printf '\n\033[36m>> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m   OK: %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m[X] %s\033[0m\n' "$1"; exit 1; }

# 默认打本机架构的包。给别的芯片打，传个参数：
#   bash build.sh intel   （给 Intel 芯片的 Mac）
#   bash build.sh apple   （给 M 系列芯片的 Mac）
ARCH=$(uname -m)
case "${1:-}" in
  intel|x86_64|x64) ARCH="x86_64" ;;
  apple|arm64|m1|m2|m3|m4) ARCH="arm64" ;;
  "") ;;
  *) die "不认识的参数「$1」。打 Intel 包：bash build.sh intel" ;;
esac
case "$ARCH" in
  arm64)  NODE_ARCH="darwin-arm64"; PANDOC_ARCH="arm64-macOS";  TOP="群星回廊-Mac" ;;
  x86_64) NODE_ARCH="darwin-x64";   PANDOC_ARCH="x86_64-macOS"; TOP="群星回廊-Mac-Intel" ;;
  *) die "不认识的架构 $ARCH" ;;
esac
WORK="$(pwd)/shufang-build"
OUT="$(pwd)/${TOP}.zip"
echo "架构：$ARCH  →  Node $NODE_ARCH / Pandoc $PANDOC_ARCH"

rm -rf "$WORK"
mkdir -p "$WORK/payload"
cd "$WORK"

# ── 程序本体 ──────────────────────────────────────────────
say "拉取程序本体"
curl -fsSL --max-time 300 -o app.zip \
  "https://codeload.github.com/URaux/shufang/zip/refs/heads/master" || die "下载失败，检查网络"
# 必须用 tar 解（bsdtar 懂 zip）：仓库里有中文文件名，GitHub 的 zip 又不带
# UTF-8 标记，macOS 的 unzip 会按 CP437 解出非法文件名，APFS 直接拒写。
tar -xf app.zip || die "解压失败"
mv shufang-master payload/app
rm -f app.zip
[ -f payload/app/webapp/server.js ] || die "拉下来的东西不对，没有 webapp/server.js"
ok "程序就绪（$(cd payload/app && git log --oneline -1 2>/dev/null || echo master)）"

# ── Node ──────────────────────────────────────────────────
# nodejs.org 的 latest-v22.x 是真·单版本目录（npmmirror 那个同名目录列的是全部版本，
# 取第一个会拿到 v22.0.0 —— 那个版本 dsh 起不来，踩过）。
say "下载 Node（macOS ${ARCH}）"
NODE_TGZ=$(curl -fsSL --max-time 60 https://nodejs.org/dist/latest-v22.x/ \
  | grep -o "node-v[0-9.]*-${NODE_ARCH}\.tar\.gz" | head -1)
[ -n "$NODE_TGZ" ] || die "取不到 Node 下载地址"
NODE_VER=$(echo "$NODE_TGZ" | sed -E 's/node-v([0-9.]+)-.*/\1/')
NODE_MAJOR=${NODE_VER%%.*}; NODE_REST=${NODE_VER#*.}; NODE_MINOR=${NODE_REST%%.*}
if [ "$NODE_MAJOR" -lt "$NODE_MIN_MAJOR" ] || \
   { [ "$NODE_MAJOR" -eq "$NODE_MIN_MAJOR" ] && [ "$NODE_MINOR" -lt "$NODE_MIN_MINOR" ]; }; then
  die "取到的 Node 是 ${NODE_VER}，低于 ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}（聊天功能依赖它）"
fi
curl -fL --progress-bar --max-time 600 -o node.tgz \
  "https://nodejs.org/dist/latest-v22.x/$NODE_TGZ" || die "Node 下载失败"
tar -xzf node.tgz
mv "node-v${NODE_VER}-${NODE_ARCH}" payload/node
rm -f node.tgz
ok "Node $NODE_VER"

# ── Pandoc ────────────────────────────────────────────────
say "下载 Pandoc"
PANDOC_URL=$(curl -fsSL --max-time 60 https://api.github.com/repos/jgm/pandoc/releases/latest \
  | grep -o "https://[^\"]*${PANDOC_ARCH}\.zip" | head -1)
[ -n "$PANDOC_URL" ] || die "取不到 Pandoc 下载地址"
curl -fL --progress-bar --max-time 600 -o pandoc.zip "$PANDOC_URL" || die "Pandoc 下载失败"
unzip -q pandoc.zip
mkdir -p payload/bin
find . -maxdepth 3 -name pandoc -type f -perm +111 -exec cp {} payload/bin/pandoc \;
[ -x payload/bin/pandoc ] || die "Pandoc 解压后没找到可执行文件"
rm -rf pandoc.zip pandoc-*
ok "Pandoc $(payload/bin/pandoc --version | head -1 | awk '{print $2}')"

# ── 安装器入口 ────────────────────────────────────────────
say "放置安装器"
cp payload/app/installer/setup-bundle-mac.sh setup-bundle-mac.sh
cat > "安装群星回廊.command" <<'LAUNCH'
#!/bin/bash
cd "$(dirname "$0")"
bash setup-bundle-mac.sh
LAUNCH
# 双击必被 Gatekeeper 拦（脚本没签名），新 macOS 连「右键打开」的口子都封了。
# 这张纸条是给被拦住的人看的，放行路径写死在这，别指望用户自己找到设置项。
cat > "打不开先看这里.txt" <<'NOTE'
双击「安装群星回廊.command」如果弹出
「Apple 无法验证…」被拦住，是正常的（脚本没花钱买苹果签名）。
两个办法任选一个：

■ 办法一（最快）
  1. 打开「终端」（启动台里搜：终端）
  2. 输入  bash （bash 后面带一个空格）
  3. 把「安装群星回廊.command」拖进终端窗口，按回车

■ 办法二（系统设置放行）
  1. 弹框里点「完成」（千万别点"移到废纸篓"）
  2. 打开「系统设置」→「隐私与安全性」，拉到最底下
  3. 看到「已阻止"安装群星回廊.command"」，点「仍要打开」，输一次开机密码
  4. 回来再双击一次

装完以后桌面上的「启动群星回廊.command」是电脑上现生成的，
不会再被拦。
NOTE
chmod +x "安装群星回廊.command" setup-bundle-mac.sh
chmod +x payload/node/bin/* payload/bin/* 2>/dev/null || true
ok "入口就绪"

# ── 打包 ──────────────────────────────────────────────────
# 必须用 macOS 自带的 zip：它会保留执行位，解压出来才双击得动、node 才跑得起来。
say "打包"
cd "$WORK"
rm -f "$OUT"
STAGE="$(mktemp -d)/$TOP"
mkdir -p "$STAGE"
cp -R payload "安装群星回廊.command" setup-bundle-mac.sh "打不开先看这里.txt" "$STAGE/"
( cd "$(dirname "$STAGE")" && zip -qry "$OUT" "$TOP" -x '*.DS_Store' )
rm -rf "$(dirname "$STAGE")"

SIZE=$(du -h "$OUT" | cut -f1)
say "完成"
echo "   $OUT  ($SIZE)"
echo ""
echo "   验一下执行位（应该看到 rwxr-xr-x）："
unzip -l "$OUT" >/dev/null && unzip -Z "$OUT" "$TOP/安装群星回廊.command" "$TOP/payload/node/bin/node" | grep -E '^-'
echo ""
echo "   发布：gh release upload <tag> \"$OUT\" --repo URaux/shufang --clobber"
