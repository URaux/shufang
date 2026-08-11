#!/bin/bash
# 书房 macOS 安装器 — 零环境友好版
#
# 特点：不用 Homebrew、不用 Xcode 命令行工具、全程不要管理员密码。
# 所有东西都装进你自己的用户目录（~/.shufang 和 ~/Applications）。
#
# 用法（终端里粘贴一行）：
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/URaux/shufang/master/installer/install-mac.sh)"
set -u

OWNER="URaux"; REPO="shufang"
APP_DIR="$HOME/.shufang"
APP_REPO="$APP_DIR/app"
NODE_DIR="$APP_DIR/node"
BIN_DIR="$APP_DIR/bin"
VAULT="$HOME/Documents/书房"
CONFIG="$APP_DIR/config.json"
LOG="/tmp/shufang-install.log"

exec > >(tee "$LOG") 2>&1

step() { printf '\n\033[36m>> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m   OK: %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m[X] %s\033[0m\n检查一下网络（GitHub 要能访问），然后重跑安装命令。\n日志在 %s，可以发给帮你装的人。\n' "$1" "$LOG"; exit 1; }

echo "=============================================="
echo "  书房 · 本地啃书翻译器 安装程序 (macOS)"
echo "  不动系统、不要密码，全装在你自己目录里"
echo "=============================================="

ARCH="$(uname -m)"   # arm64 (M 系芯片) 或 x86_64 (Intel)
mkdir -p "$APP_DIR" "$BIN_DIR" "$HOME/Applications"

# ---------------------------------------------------------------- Node
step "安装 Node（网页程序的运行环境）"
if [ ! -x "$NODE_DIR/bin/node" ]; then
  NODE_TGZ=$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ | grep -o "node-v[0-9.]*-darwin-$ARCH.tar.gz" | head -1)
  [ -n "$NODE_TGZ" ] || die "取不到 Node 下载地址"
  echo "   下载 $NODE_TGZ ..."
  curl -fL --progress-bar "https://nodejs.org/dist/latest-v22.x/$NODE_TGZ" -o /tmp/shufang-node.tgz || die "Node 下载失败"
  rm -rf "$NODE_DIR" /tmp/shufang-node
  mkdir -p /tmp/shufang-node
  tar -xzf /tmp/shufang-node.tgz -C /tmp/shufang-node || die "Node 解压失败"
  mv /tmp/shufang-node/node-v* "$NODE_DIR"
  rm -rf /tmp/shufang-node.tgz /tmp/shufang-node
fi
export PATH="$NODE_DIR/bin:$BIN_DIR:$PATH"
ok "Node $(node --version 2>/dev/null) 就绪"

# ---------------------------------------------------------------- Pandoc
step "安装 Pandoc（电子书格式转换）"
if [ ! -x "$BIN_DIR/pandoc" ]; then
  PARCH=$([ "$ARCH" = "arm64" ] && echo "arm64" || echo "x86_64")
  PANDOC_URL=$(curl -fsSL https://api.github.com/repos/jgm/pandoc/releases/latest | grep -o "https://[^\"]*${PARCH}-macOS.zip" | head -1)
  [ -n "$PANDOC_URL" ] || die "取不到 Pandoc 下载地址"
  curl -fL --progress-bar "$PANDOC_URL" -o /tmp/shufang-pandoc.zip || die "Pandoc 下载失败"
  rm -rf /tmp/shufang-pandoc
  unzip -qo /tmp/shufang-pandoc.zip -d /tmp/shufang-pandoc || die "Pandoc 解压失败"
  find /tmp/shufang-pandoc -type f -name pandoc -exec cp {} "$BIN_DIR/pandoc" \;
  chmod +x "$BIN_DIR/pandoc"
  rm -rf /tmp/shufang-pandoc.zip /tmp/shufang-pandoc
fi
ok "Pandoc 就绪"

# ---------------------------------------------------------------- Obsidian
step "安装 Obsidian（看书和笔记的界面）"
if [ ! -d "/Applications/Obsidian.app" ] && [ ! -d "$HOME/Applications/Obsidian.app" ]; then
  DMG_URL=$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest | grep -o 'https://[^"]*universal.dmg' | head -1)
  [ -n "$DMG_URL" ] || die "取不到 Obsidian 下载地址"
  curl -fL --progress-bar "$DMG_URL" -o /tmp/shufang-obsidian.dmg || die "Obsidian 下载失败"
  MNT=$(hdiutil attach -nobrowse -readonly /tmp/shufang-obsidian.dmg | grep -o '/Volumes/.*' | head -1)
  [ -n "$MNT" ] || die "Obsidian 安装包打不开"
  cp -R "$MNT/Obsidian.app" "$HOME/Applications/" || { hdiutil detach "$MNT" >/dev/null 2>&1; die "Obsidian 复制失败"; }
  hdiutil detach "$MNT" >/dev/null 2>&1
  rm -f /tmp/shufang-obsidian.dmg
  # 先启动一次，让系统记住 obsidian:// 链接归它管
  open -a "$HOME/Applications/Obsidian.app" --hide 2>/dev/null || true
fi
ok "Obsidian 就绪"

# ---------------------------------------------------------------- Claude Code
step "安装 Claude Code（翻译助手的大脑）"
if [ ! -x "$NODE_DIR/bin/claude" ]; then
  "$NODE_DIR/bin/npm" install -g @anthropic-ai/claude-code || die "Claude Code 安装失败"
fi
ok "Claude Code 就绪"

# ---------------------------------------------------------------- API key
step "配置 DeepSeek"
echo "   需要一个 DeepSeek API key（在 platform.deepseek.com 注册后创建，sk- 开头）。"
KEY=""
while [[ ! "$KEY" =~ ^sk- ]]; do
  printf '   粘贴你的 DeepSeek API key: '
  read -r KEY </dev/tty
  [[ "$KEY" =~ ^sk- ]] || echo "   看起来不太对，应该是 sk- 开头的一串。再试一次。"
done

# ---------------------------------------------------------------- 程序本体
step "获取书房程序（之后每次启动自动检查更新）"
fetch_app() {
  local sha
  sha=$(curl -fsSL "https://api.github.com/repos/$OWNER/$REPO/commits/master" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
  curl -fsSL "https://codeload.github.com/$OWNER/$REPO/tar.gz/master" -o /tmp/shufang-app.tgz || return 1
  rm -rf /tmp/shufang-app
  mkdir -p /tmp/shufang-app
  tar -xzf /tmp/shufang-app.tgz -C /tmp/shufang-app || return 1
  rm -rf "$APP_REPO"
  mv /tmp/shufang-app/"$REPO"-master "$APP_REPO"
  [ -n "$sha" ] && printf '%s' "$sha" > "$APP_DIR/.app-sha"
  rm -rf /tmp/shufang-app.tgz /tmp/shufang-app
}
fetch_app || die "从 GitHub 获取程序失败"
ok "已获取最新版"

if [ -d "$VAULT" ]; then
  ok "书库已存在（$VAULT），保留原样"
else
  cp -R "$APP_REPO/vault-template" "$VAULT"
  ok "书库建在 $VAULT"
fi

( cd "$APP_REPO/webapp" && "$NODE_DIR/bin/npm" install --omit=dev --silent ) || die "网页程序依赖安装失败"
ok "网页程序就绪"

TOKEN=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12)
cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "port": 7787,
  "token": "$TOKEN",
  "env": {
    "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "$KEY",
    "ANTHROPIC_MODEL": "deepseek-v4-pro",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-v4-pro",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-flash",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-v4-flash",
    "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-v4-flash",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
EOF
ok "配置写好了"

# ---------------------------------------------------------------- 启动器
step "创建桌面启动器"
LAUNCHER="$HOME/Desktop/启动书房.command"
cat > "$LAUNCHER" <<'LAUNCH_EOF'
#!/bin/bash
APP_DIR="$HOME/.shufang"
APP_REPO="$APP_DIR/app"
VAULT="$HOME/Documents/书房"
export PATH="$APP_DIR/node/bin:$APP_DIR/bin:$PATH"

# 检查更新：远端 commit 变了才重新下载（约 300KB），没变秒过
echo "检查更新中..."
LATEST=$(curl -fsSL --max-time 8 "https://api.github.com/repos/URaux/shufang/commits/master" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
CURRENT=$(cat "$APP_DIR/.app-sha" 2>/dev/null || true)
if [ -n "$LATEST" ] && [ "$LATEST" != "$CURRENT" ]; then
  echo "发现新版本，更新中..."
  if curl -fsSL --max-time 60 "https://codeload.github.com/URaux/shufang/tar.gz/master" -o /tmp/shufang-up.tgz; then
    rm -rf /tmp/shufang-up && mkdir -p /tmp/shufang-up
    if tar -xzf /tmp/shufang-up.tgz -C /tmp/shufang-up 2>/dev/null; then
      rm -rf "$APP_REPO"
      mv /tmp/shufang-up/shufang-master "$APP_REPO"
      printf '%s' "$LATEST" > "$APP_DIR/.app-sha"
      ( cd "$APP_REPO/webapp" && npm install --omit=dev --silent >/dev/null 2>&1 )
      # 同步助手的说明书到书库（你自己的书和笔记不会被动）
      cp -R "$APP_REPO/vault-template/.claude" "$VAULT/" 2>/dev/null
      cp "$APP_REPO/vault-template/CLAUDE.md" "$VAULT/" 2>/dev/null
      echo "已更新到最新版。"
    fi
    rm -rf /tmp/shufang-up.tgz /tmp/shufang-up
  fi
fi

# 纯 bash 的 URL 编码（不依赖 python）。LC_ALL=C 让循环按字节走，
# 这样中文路径（书房）会被正确编码成 UTF-8 的 %E4%B9%A6... 序列。
urlencode() {
  local LC_ALL=C
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9./_-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}
open "obsidian://open?path=$(urlencode "$VAULT")" 2>/dev/null || open -a Obsidian 2>/dev/null || true
( sleep 2; open "http://localhost:7787/" ) &
cd "$APP_REPO/webapp" || exit 1
exec node server.js
LAUNCH_EOF
chmod +x "$LAUNCHER"
ok "桌面上有「启动书房.command」了"

echo ""
echo "=============================================="
echo "  安装完成！"
echo "  双击桌面「启动书房.command」开始用。"
echo "  第一次系统若拦截，右键它选「打开」一次即可。"
echo "  第一次 Obsidian 打开时选「信任此仓库」。"
echo "=============================================="
