#!/bin/bash
# 给「用全量包装过、但桌面启动器没有自动更新」的 Mac 用户补一次。
#
# 背景：Mac 有两条安装路径，一行命令装的启动器带自动更新，
# 全量包（zip）装的**不带**——那批人的桌面启动器只会起服务和开浏览器，
# 所以他们永远停在打包那天的版本，重启多少次都不会更新，也不会看到任何提示。
# 全量包安装器本身已经修好了，但启动器是安装时写死在桌面上的文件，
# 已经装好的那批不会自己变，只能补跑这个。
#
# 用法（在终端里贴一行）：
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/URaux/shufang/master/installer/fix-mac-updater.sh)"
#
# 这个脚本做两件事：立刻更新到最新版；把启动器换成带自动更新的版本。
# 不碰你的书库、配置、密钥。

set -euo pipefail

APP_DIR="$HOME/.shufang"
APP_REPO="$APP_DIR/app"
CONFIG="$APP_DIR/config.json"
LAUNCHER="$HOME/Desktop/启动群星回廊.command"
OLD_LAUNCHER="$HOME/Desktop/启动群星阅览室.command"   # 改名前的旧文件名

say()  { printf '\n\033[36m>> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m   OK: %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m[X] %s\033[0m\n' "$1"; exit 1; }

[ -d "$APP_REPO" ] || die "没找到 $APP_REPO，这台机器上好像没装过。"

# 书库位置从配置里读，读不到就用默认。烤进启动器要用它。
VAULT=""
if [ -f "$CONFIG" ]; then
  VAULT=$(sed -n 's/.*"vaultPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)
fi
[ -n "$VAULT" ] || VAULT="$HOME/Documents/书房"
ok "书库：$VAULT"

# ── 1. 先更新一次 ────────────────────────────────────────
say "更新到最新版"
LATEST=$(curl -fsSL --max-time 15 "https://api.github.com/repos/URaux/shufang/commits/master" 2>/dev/null \
  | grep -m1 '"sha"' | cut -d'"' -f4 || true)
[ -n "$LATEST" ] || die "连不上 GitHub，换个网络再试。"
CURRENT=$(cat "$APP_DIR/.app-sha" 2>/dev/null || true)

if [ "$LATEST" = "$CURRENT" ]; then
  ok "已经是最新版了（${LATEST:0:8}）"
else
  # 下载刚才校验的那个 sha，不再要一次 master——两次请求之间 master 可能已经动了
  curl -fsSL --max-time 120 "https://codeload.github.com/URaux/shufang/tar.gz/$LATEST" \
    -o /tmp/shufang-fix.tgz || die "下载失败"
  rm -rf /tmp/shufang-fix && mkdir -p /tmp/shufang-fix
  tar -xzf /tmp/shufang-fix.tgz -C /tmp/shufang-fix || die "解压失败"
  SRC=$(find /tmp/shufang-fix -maxdepth 1 -type d -name 'shufang-*' | head -1)
  [ -n "$SRC" ] || die "包里的结构不对"

  rm -rf "$APP_DIR/app.old"
  mv "$APP_REPO" "$APP_DIR/app.old" || die "旧版本挪不开，可能程序还开着——先退出再跑一次"
  if mv "$SRC" "$APP_REPO"; then
    printf '%s' "$LATEST" > "$APP_DIR/.app-sha"
    cp -R "$APP_REPO/vault-template/.claude" "$VAULT/" 2>/dev/null || true
    cp "$APP_REPO/vault-template/CLAUDE.md" "$VAULT/" 2>/dev/null || true
    rm -rf "$APP_DIR/app.old"
    ok "更新到 ${LATEST:0:8}"
  else
    mv "$APP_DIR/app.old" "$APP_REPO" 2>/dev/null || true
    die "替换失败，已回滚到原来的版本"
  fi
  rm -rf /tmp/shufang-fix.tgz /tmp/shufang-fix
fi

# ── 2. 换掉启动器 ────────────────────────────────────────
say "把桌面启动器换成会自动更新的"

# 旧名字的那个一并处理掉，免得桌面上留着一个永远不更新的入口
if [ -f "$OLD_LAUNCHER" ] && [ ! -f "$LAUNCHER" ]; then
  mv "$OLD_LAUNCHER" "$LAUNCHER"
  ok "顺手把「启动群星阅览室」改名成「启动群星回廊」"
elif [ -f "$OLD_LAUNCHER" ]; then
  rm -f "$OLD_LAUNCHER"
  ok "删掉了旧名字的那个入口（新的叫「启动群星回廊」）"
fi

cat > "$LAUNCHER" <<LAUNCH_EOF
#!/bin/bash
APP_DIR="$APP_DIR"
APP_REPO="\$APP_DIR/app"
VAULT_DIR="$VAULT"
export PATH="\$APP_DIR/node/bin:\$APP_DIR/bin:\$PATH"

echo "检查更新中..."
LATEST=\$(curl -fsSL --max-time 8 "https://api.github.com/repos/URaux/shufang/commits/master" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
CURRENT=\$(cat "\$APP_DIR/.app-sha" 2>/dev/null || true)
if [ -n "\$LATEST" ] && [ "\$LATEST" != "\$CURRENT" ]; then
  echo "发现新版本，更新中..."
  if curl -fsSL --max-time 60 "https://codeload.github.com/URaux/shufang/tar.gz/\$LATEST" -o /tmp/shufang-up.tgz; then
    rm -rf /tmp/shufang-up && mkdir -p /tmp/shufang-up
    SRC=""
    if tar -xzf /tmp/shufang-up.tgz -C /tmp/shufang-up 2>/dev/null; then
      SRC=\$(find /tmp/shufang-up -maxdepth 1 -type d -name 'shufang-*' | head -1)
    fi
    if [ -n "\$SRC" ]; then
      rm -rf "\$APP_DIR/app.old"
      if ! mv "\$APP_REPO" "\$APP_DIR/app.old" 2>/dev/null; then
        echo "旧版本挪不开，这次跳过更新。"
        SRC=""
      fi
    fi
    if [ -n "\$SRC" ]; then
      if mv "\$SRC" "\$APP_REPO"; then
        printf '%s' "\$LATEST" > "\$APP_DIR/.app-sha"
        cp -R "\$APP_REPO/vault-template/.claude" "\$VAULT_DIR/" 2>/dev/null
        cp "\$APP_REPO/vault-template/CLAUDE.md" "\$VAULT_DIR/" 2>/dev/null
        rm -rf "\$APP_DIR/app.old"
        echo "已更新到最新版。"
      else
        mv "\$APP_DIR/app.old" "\$APP_REPO" 2>/dev/null
        echo "更新失败，继续用当前版本。"
      fi
    fi
    rm -rf /tmp/shufang-up.tgz /tmp/shufang-up
  fi
fi

cd "\$APP_REPO/webapp" || exit 1
node server.js &
SRV=\$!
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
ok "桌面启动器已经换好，以后每次启动会自己检查更新"

say "完事"
echo "   双击桌面「启动群星回廊.command」就行。"
echo "   更新信息会打在终端窗口里（不是弹框），看到「已更新到最新版」就是成功了。"
