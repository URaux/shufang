#!/bin/bash
# 群星回廊 · Mac 全量包安装器
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
echo "  群星回廊 · 全量包安装 (macOS)"
echo "  Node/Pandoc/程序都在包里，不用下载"
echo "=============================================="

[ -x "$PAYLOAD/node/bin/node" ] || die "找不到安装材料。你可能是在压缩包里直接双击的——请先把整个压缩包解压出来再运行。"

# ---------------------------------------------------------------- 先停掉在跑的
step "检查有没有正在运行的群星回廊"
STOPPED=$(pkill -f "$APP_DIR_DEFAULT/app/webapp/server.js" 2>/dev/null; echo $?)
sleep 1
ok "检查完毕"

# ---------------------------------------------------------------- 读老配置
# 必须在问位置**之前**读。原来这段在下面，而上面的默认值就已经用了 $OLD_VAULT，
# 那时候它还是空的 —— 结果 Mac 用户升级时一路回车，书库被悄悄挪回 Documents。
# 升级场景：key / token / 端口 / 书库位置全部沿用，别让人重填。
# token 换了的话，手机上存的那个带 ?t= 的链接会全部失效。
CONFIG_DIR="$HOME/.shufang"
CONFIG="$CONFIG_DIR/config.json"
OLD_KEY=""; OLD_TOKEN=""; OLD_VAULT=""
if [ -f "$CONFIG" ]; then
  OLD_KEY=$(  sed -n 's/.*"DEEPSEEK_API_KEY"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)
  OLD_TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'            "$CONFIG" | head -1)
  OLD_VAULT=$(sed -n 's/.*"vaultPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'        "$CONFIG" | head -1)
  case "$OLD_KEY" in sk-*|enc:v1:*) ;; *) OLD_KEY="" ;; esac
  [ -d "$OLD_VAULT" ] || OLD_VAULT=""
fi
# 老书库在哪就还用哪
[ -n "$OLD_VAULT" ] && VAULT_DEFAULT="$OLD_VAULT"

# ---------------------------------------------------------------- 位置选择
# 空间也要说清楚：只写「不够就换个地方」，用户既不知道要多少也不知道自己剩多少。
free_mb() { df -m "$(dirname "$1")" 2>/dev/null | awk 'NR==2{print $4}'; }
NEED_APP_MB=900
NEED_VAULT_MB=200

echo ""
echo "程序装到哪？（约 700MB）"
printf '\033[90m   这个盘还剩 %s MB\033[0m\n' "$(free_mb "$APP_DIR_DEFAULT")"
echo "直接回车用默认: $APP_DIR_DEFAULT"
read -r APP_DIR </dev/tty
[ -z "$APP_DIR" ] && APP_DIR="$APP_DIR_DEFAULT"

echo ""
echo "书库放到哪？（你的书、译文、笔记）"
echo "直接回车用默认: $VAULT_DEFAULT"
read -r VAULT </dev/tty
[ -z "$VAULT" ] && VAULT="$VAULT_DEFAULT"

# 选完真核一遍，别等复制到一半才炸
for pair in "$APP_DIR:$NEED_APP_MB:程序" "$VAULT:$NEED_VAULT_MB:书库"; do
  d="${pair%%:*}"; rest="${pair#*:}"; need="${rest%%:*}"; what="${rest#*:}"
  avail=$(free_mb "$d")
  if [ -n "$avail" ] && [ "$avail" -lt "$need" ] 2>/dev/null; then
    die "$(dirname "$d") 只剩 ${avail} MB，装不下${what}（要 ${need} MB）。换个空间大的位置重跑一次。"
  fi
done

NODE_DIR="$APP_DIR/node"
BIN_DIR="$APP_DIR/bin"
APP_REPO="$APP_DIR/app"

mkdir -p "$APP_DIR" "$CONFIG_DIR"

# ---------------------------------------------------------------- 落料
step "安放运行环境（Node + Pandoc，已内置）"
rm -rf "$NODE_DIR" "$BIN_DIR"
cp -R "$PAYLOAD/node" "$NODE_DIR" || die "复制 Node 失败"
cp -R "$PAYLOAD/bin" "$BIN_DIR" || die "复制 Pandoc 失败"
chmod +x "$NODE_DIR/bin/"* "$BIN_DIR/"* 2>/dev/null
# macOS 会给下载来的可执行文件打隔离标记，去掉它才不会每个都弹「无法验证开发者」
xattr -dr com.apple.quarantine "$NODE_DIR" "$BIN_DIR" 2>/dev/null || true
# dsh 的会话存储要 Node 22.15 才有的 zstd 接口。版本低了 dsh 一启动就崩，
# 表现是聊天完全没反应，而入库还好好的（那条路直连 API 不经过 dsh），很难猜。
NODE_VER=$("$NODE_DIR/bin/node" --version 2>/dev/null | tr -d 'v')
# 用 case 而不是 sort -V：不同 macOS 的 sort 行为不完全一致，这里不值得赌
case "$NODE_VER" in
  22.0.*|22.1.*|22.2.*|22.3.*|22.4.*|22.5.*|22.6.*|22.7.*|22.8.*|22.9.*|22.1[0-4].*)
    die "这个安装包里的 Node 是 $NODE_VER，太旧了（要 22.15 以上，聊天功能依赖它）。请重新下载安装包。" ;;
esac
ok "运行环境就绪（Node $NODE_VER）"

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

# ---------------------------------------------------------------- Obsidian
# 译文是机器翻的，一定有要改的地方，而 Obsidian 读写的就是书库里那批 .md，
# 改完这边立刻看得到。所以它是默认装的一环，不是可选配件。
# 它是闭源软件，不能塞进我们的压缩包分发，只能从官方下载。
# 但装不上绝不能让整个安装失败——群星回廊自带网页界面，照样能看能改。
step "检查 Obsidian（用来自己改译文、做笔记）"
if [ -d "/Applications/Obsidian.app" ] || [ -d "$HOME/Applications/Obsidian.app" ]; then
  ok "已经装过了"
else
  printf '\033[90m   要下载 218MB。网不好可以按 n 跳过，以后重跑安装器随时能补。\033[0m\n'
  printf '   现在装吗 (Y/n): '
  read -r WANT_OBS </dev/tty
  if [[ "$WANT_OBS" =~ ^[Nn] ]]; then
    printf '\033[90m   跳过了。网页界面照常能看能改。\033[0m\n'
  else
    obs_ok=0
    # 资产名是 Obsidian-<版本>.dmg
    DMG=$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
      | grep -o 'https://[^"]*/Obsidian-[0-9.]*\.dmg' | head -1)
    if [ -n "$DMG" ] && curl -fL --progress-bar "$DMG" -o /tmp/shufang-obsidian.dmg; then
      MNT=$(hdiutil attach -nobrowse -readonly /tmp/shufang-obsidian.dmg | grep -o '/Volumes/.*' | head -1)
      if [ -n "$MNT" ]; then
        mkdir -p "$HOME/Applications"
        cp -R "$MNT/Obsidian.app" "$HOME/Applications/" && obs_ok=1
        hdiutil detach "$MNT" >/dev/null 2>&1
      fi
    fi
    rm -f /tmp/shufang-obsidian.dmg
    if [ "$obs_ok" = "1" ]; then
      xattr -dr com.apple.quarantine "$HOME/Applications/Obsidian.app" 2>/dev/null || true
      # 先起一次，让系统记住 obsidian:// 链接归它管
      open -a "$HOME/Applications/Obsidian.app" --hide 2>/dev/null || true
      ok "Obsidian 装好了"
    else
      printf '\033[33m   Obsidian 这一步没成，不影响使用。联网后重跑一次安装器就能补上。\033[0m\n'
    fi
  fi
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
LAUNCHER="$HOME/Desktop/启动群星回廊.command"
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
ok "桌面上有「启动群星回廊.command」了"

echo ""
echo "=============================================="
echo "  安装完成！"
echo "  程序在: $APP_DIR"
echo "  书库在: $VAULT"
echo "  双击桌面「启动群星回廊.command」开始用。"
echo "  第一次运行若被系统拦，右键它选「打开」一次即可。"
echo "=============================================="
