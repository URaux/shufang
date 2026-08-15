#!/bin/bash
# 群星阅览室 · Mac 全量包安装器
#
# Node、Pandoc、程序本体都在包里，不用下载。
# 只有 dsh（翻译大脑）要联网装一次——它有个原生组件必须在本机编译，
# 没法预先打进包里（在 Windows 上交叉编译试过，失败）。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$HERE/payload"
APP_DIR_DEFAULT="$HOME/.shufang"
VAULT_DEFAULT="$HOME/Documents/书房"
LOG="/tmp/shufang-install.log"

exec > >(tee "$LOG") 2>&1

step() { printf '\n\033[36m>> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m   OK: %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m[X] %s\033[0m\n日志在 %s，可以发给帮你装的人。\n' "$1" "$LOG"; exit 1; }

echo "=============================================="
echo "  群星阅览室 · 全量包安装 (macOS)"
echo "  Node/Pandoc/程序都在包里，不用下载"
echo "=============================================="

[ -x "$PAYLOAD/node/bin/node" ] || die "找不到安装材料。你可能是在压缩包里直接双击的——请先把整个压缩包解压出来再运行。"

# ---------------------------------------------------------------- 先停掉在跑的
step "检查有没有正在运行的群星阅览室"
STOPPED=$(pkill -f "$APP_DIR_DEFAULT/app/webapp/server.js" 2>/dev/null; echo $?)
sleep 1
ok "检查完毕"

# ---------------------------------------------------------------- 位置选择
echo ""
echo "程序装到哪？（约 700MB）"
echo "直接回车用默认: $APP_DIR_DEFAULT"
read -r APP_DIR </dev/tty
[ -z "$APP_DIR" ] && APP_DIR="$APP_DIR_DEFAULT"

echo ""
echo "书库放到哪？（你的书、译文、笔记）"
echo "直接回车用默认: $VAULT_DEFAULT"
read -r VAULT </dev/tty
[ -z "$VAULT" ] && VAULT="${OLD_VAULT:-$VAULT_DEFAULT}"

NODE_DIR="$APP_DIR/node"
BIN_DIR="$APP_DIR/bin"
APP_REPO="$APP_DIR/app"
CONFIG_DIR="$HOME/.shufang"
CONFIG="$CONFIG_DIR/config.json"

# ---------------------------------------------------------------- 读老配置
# 升级场景：key / token / 端口 / 书库位置沿用，别让人重填。
# token 换了的话，手机上存的那个带 ?t= 的链接会全部失效。
OLD_KEY=""; OLD_TOKEN=""; OLD_VAULT=""
if [ -f "$CONFIG" ]; then
  OLD_KEY=$(  sed -n 's/.*"DEEPSEEK_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)
  OLD_TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'            "$CONFIG" | head -1)
  OLD_VAULT=$(sed -n 's/.*"vaultPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'        "$CONFIG" | head -1)
  case "$OLD_KEY" in sk-*|enc:v1:*) ;; *) OLD_KEY="" ;; esac
  [ -d "$OLD_VAULT" ] || OLD_VAULT=""
fi

mkdir -p "$APP_DIR" "$CONFIG_DIR"

# ---------------------------------------------------------------- 落料
step "安放运行环境（Node + Pandoc，已内置）"
rm -rf "$NODE_DIR" "$BIN_DIR"
cp -R "$PAYLOAD/node" "$NODE_DIR" || die "复制 Node 失败"
cp -R "$PAYLOAD/bin" "$BIN_DIR" || die "复制 Pandoc 失败"
chmod +x "$NODE_DIR/bin/"* "$BIN_DIR/"* 2>/dev/null
# macOS 会给下载来的可执行文件打隔离标记，去掉它才不会每个都弹「无法验证开发者」
xattr -dr com.apple.quarantine "$NODE_DIR" "$BIN_DIR" 2>/dev/null || true
ok "运行环境就绪"

step "安放程序本体"
rm -rf "$APP_REPO"
cp -R "$PAYLOAD/app" "$APP_REPO" || die "复制程序失败"
ok "程序就绪"

step "建书库"
if [ -d "$VAULT" ]; then
  ok "书库已存在（$VAULT），保留原样"
else
  cp -R "$APP_REPO/vault-template" "$VAULT" || die "建书库失败"
  ok "书库建在 $VAULT"
fi

export PATH="$NODE_DIR/bin:$BIN_DIR:$PATH"

# ---------------------------------------------------------------- dsh（唯一要联网的一步）
step "安装翻译大脑 dsh（这一步要联网，约一两分钟）"
if [ ! -x "$NODE_DIR/bin/dsh" ]; then
  "$NODE_DIR/bin/npm" install -g @deepseek-ai/dsh --silent 2>&1 | tail -3 || \
    printf '\033[33m   dsh 没装上（可能没网）。看书功能不受影响，联网后重跑一次本安装器即可。\033[0m\n'
fi
[ -x "$NODE_DIR/bin/dsh" ] && ok "dsh 就绪" || true

# ---------------------------------------------------------------- PDF 支持
step "检查 PDF 支持"
if command -v python3 >/dev/null 2>&1; then
  # 版本钉死，理由同 Windows：新版 import 时硬拉 onnxruntime，容易整个崩掉
  python3 -m pip install --quiet --user "pymupdf4llm==0.0.27" 2>/dev/null && ok "PDF 支持就绪" || \
    printf '\033[33m   PDF 支持没装上（不影响 epub/txt/docx）。\033[0m\n'
else
  printf '\033[33m   这台电脑没装 python3，PDF 格式的书暂时读不了（epub/txt/docx 不受影响）。\033[0m\n'
fi

# ---------------------------------------------------------------- API key
step "配置 DeepSeek"
echo "   需要一个 DeepSeek API key（platform.deepseek.com 注册后创建，sk- 开头）。"
echo "   粘贴时屏幕不显示，这是正常的——粘完直接回车。"
KEY="$OLD_KEY"
[ -n "$KEY" ] && ok "沿用你上次填的 key（想换：删掉 $CONFIG 再装一遍）"
while [[ ! "$KEY" =~ ^(sk-|enc:v1:) ]]; do
  printf '   粘贴你的 DeepSeek API key: '
  read -rs KEY </dev/tty
  echo ""
  [[ "$KEY" =~ ^sk- ]] || echo "   看起来不太对，应该是 sk- 开头的一串。再试一次。"
done

TOKEN="$OLD_TOKEN"
[ -z "$TOKEN" ] && TOKEN=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 24)
cat > "$CONFIG" <<EOF
{
  "vaultPath": "$VAULT",
  "port": 7787,
  "token": "$TOKEN",
  "brain": "dsh",
  "env": {
    "DEEPSEEK_API_KEY": "$KEY"
  }
}
EOF
chmod 600 "$CONFIG"
KEY=""
ok "配置写好了"

# ---------------------------------------------------------------- 启动器
step "创建桌面启动器"
LAUNCHER="$HOME/Desktop/启动群星阅览室.command"
cat > "$LAUNCHER" <<LAUNCH_EOF
#!/bin/bash
APP_DIR="$APP_DIR"
export PATH="\$APP_DIR/node/bin:\$APP_DIR/bin:\$PATH"
cd "\$APP_DIR/app/webapp" || exit 1
node server.js &
SRV=\$!
# 等端口起来再开浏览器
for i in \$(seq 1 40); do
  sleep 1
  P=\$(cat "\$APP_DIR/last-port" 2>/dev/null || echo 7787)
  if curl -s -o /dev/null "http://localhost:\$P/api/status"; then
    open "http://localhost:\$P/"
    break
  fi
done
wait \$SRV
LAUNCH_EOF
chmod +x "$LAUNCHER"
xattr -d com.apple.quarantine "$LAUNCHER" 2>/dev/null || true
ok "桌面上有「启动群星阅览室.command」了"

echo ""
echo "=============================================="
echo "  安装完成！"
echo "  程序在: $APP_DIR"
echo "  书库在: $VAULT"
echo "  双击桌面「启动群星阅览室.command」开始用。"
echo "  第一次运行若被系统拦，右键它选「打开」一次即可。"
echo "=============================================="
