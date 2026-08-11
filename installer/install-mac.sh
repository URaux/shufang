#!/bin/bash
# 书房 macOS 安装器
# 用法（终端里粘贴一行）：
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/URaux/shufang/master/installer/install-mac.sh)"
set -u

REPO_URL="https://github.com/URaux/shufang.git"
APP_DIR="$HOME/.shufang"
APP_REPO="$APP_DIR/app"
VAULT="$HOME/Documents/书房"
CONFIG="$APP_DIR/config.json"
LOG="/tmp/shufang-install.log"

exec > >(tee "$LOG") 2>&1

step() { printf '\n\033[36m>> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m   OK: %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m[X] %s\033[0m\n日志在 %s，可以发给帮你装的人。\n' "$1" "$LOG"; exit 1; }

echo "=============================================="
echo "  书房 · 本地啃书翻译器 安装程序 (macOS)"
echo "=============================================="

# ---------------------------------------------------------------- Homebrew
step "检查 Homebrew（Mac 的软件管家）"
if ! command -v brew >/dev/null 2>&1; then
  # Apple Silicon 装在 /opt/homebrew，Intel 在 /usr/local——都探一遍再放弃
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "   没装过 Homebrew，现在装（会要你输一次开机密码，输的时候屏幕不显示，正常）..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die "Homebrew 安装失败"
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"
fi
command -v brew >/dev/null 2>&1 || die "Homebrew 还是不可用，重开终端再跑一次安装命令试试"
ok "Homebrew 就绪"

# ---------------------------------------------------------------- 依赖
step "安装基础组件（Node / Git / Pandoc / Obsidian）"
brew list node >/dev/null 2>&1 || brew install node || die "Node 安装失败"
command -v git >/dev/null 2>&1 || brew install git || die "Git 安装失败"
brew list pandoc >/dev/null 2>&1 || brew install pandoc || die "Pandoc 安装失败"
[ -d "/Applications/Obsidian.app" ] || brew install --cask obsidian || die "Obsidian 安装失败"
ok "基础组件就绪"

step "安装 Claude Code（翻译助手的大脑）"
if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code || die "Claude Code 安装失败"
fi
ok "Claude Code 就绪"

printf '要支持 PDF 格式的书吗？会多装一个 Python 组件 (y/N): '
read -r PDF
if [[ "$PDF" =~ ^[Yy] ]]; then
  step "安装 PDF 支持"
  command -v python3 >/dev/null 2>&1 || brew install python || die "Python 安装失败"
  python3 -m pip install --quiet --user pymupdf4llm || die "pymupdf4llm 安装失败"
  ok "PDF 支持就绪"
fi

# ---------------------------------------------------------------- API key
step "配置 DeepSeek"
echo "   需要一个 DeepSeek API key（在 platform.deepseek.com 注册后创建，sk- 开头）。"
KEY=""
while [[ ! "$KEY" =~ ^sk- ]]; do
  printf '   粘贴你的 DeepSeek API key: '
  read -r KEY
  [[ "$KEY" =~ ^sk- ]] || echo "   看起来不太对，应该是 sk- 开头的一串。再试一次。"
done

# ---------------------------------------------------------------- 落盘
step "获取书房程序（从 GitHub，之后每次启动自动更新）"
mkdir -p "$APP_DIR"
if [ -d "$APP_REPO/.git" ]; then
  git -C "$APP_REPO" pull --ff-only >/dev/null 2>&1
  ok "已有安装，拉取了最新版"
else
  rm -rf "$APP_REPO"
  git clone --depth 1 "$REPO_URL" "$APP_REPO" || die "从 GitHub 获取程序失败，检查网络后重试"
  ok "已从 GitHub 获取最新版"
fi

if [ -d "$VAULT" ]; then
  ok "书库已存在（$VAULT），保留原样"
else
  cp -R "$APP_REPO/vault-template" "$VAULT"
  ok "书库建在 $VAULT"
fi

( cd "$APP_REPO/webapp" && npm install --omit=dev --silent ) || die "网页程序依赖安装失败"
ok "网页程序就绪"

TOKEN=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 12)
NODE_BIN="$(command -v node)"
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
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-v4-pro",
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
cat > "$LAUNCHER" <<EOF
#!/bin/bash
# PATH 补全：.command 双击时的环境很干净，brew 的路径要自己加回来
export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"
cd "$APP_REPO" || exit 1
echo "检查更新中..."
git pull --ff-only >/dev/null 2>&1
cd webapp
npm install --omit=dev --silent >/dev/null 2>&1
# 同步助手的说明书到书库（你自己的书和笔记不会被动）
cp -R "$APP_REPO/vault-template/.claude" "$VAULT/" 2>/dev/null
cp "$APP_REPO/vault-template/CLAUDE.md" "$VAULT/" 2>/dev/null
open "obsidian://open?path=\$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$VAULT" 2>/dev/null || echo "$VAULT")"
sleep 1
open "http://localhost:7787/"
exec node server.js
EOF
chmod +x "$LAUNCHER"
ok "桌面上有「启动书房.command」了"

echo ""
echo "=============================================="
echo "  安装完成！"
echo "  双击桌面「启动书房.command」开始用。"
echo "  第一次系统若拦截，右键它选「打开」一次即可。"
echo "  第一次 Obsidian 打开时选「信任此仓库」。"
echo "=============================================="
