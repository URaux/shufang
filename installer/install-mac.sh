#!/bin/bash
# 群星回廊 macOS 安装器 — 零环境友好版
#
# 特点：不用 Homebrew、不用 Xcode 命令行工具、全程不要管理员密码。
# 所有东西都装进你自己的用户目录（~/.shufang 和 ~/Applications）。
#
# 用法（终端里粘贴一行）：
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/URaux/shufang/master/installer/install-mac.sh)"
set -u

OWNER="URaux"; REPO="shufang"
# 国内下载源。装机的人在国内，codeload 时好时坏而且没有可靠反代，
# 所以自己在 Cloudflare R2 上放了一份（download.gnosaria.com，国内可达），GitHub 兜底。
# 那份包是发布时同步上去的，顶层目录跟 codeload 一样叫 shufang-master/，解压代码两个源通用。
MIRROR="https://download.gnosaria.com/shufang"
APP_DIR="$HOME/.shufang"
APP_REPO="$APP_DIR/app"
NODE_DIR="$APP_DIR/node"
BIN_DIR="$APP_DIR/bin"
VAULT="$HOME/Documents/书房"
CONFIG="$APP_DIR/config.json"

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
# 老书库在哪就还用哪，别把人的书悄悄挪回 Documents
[ -n "$OLD_VAULT" ] && VAULT="$OLD_VAULT"

# 日志放 ~/.shufang/install.log 而不是 /tmp：用户找不到 /tmp（访达里根本不显示），
# 「把日志发给帮你装的人」这句话对他们等于没说。桌面的「复制群星回廊日志」和程序里的
# 「复制诊断日志」都从这儿读。追加而不是覆盖：上一次是怎么失败的经常正是线索。
LOG="$APP_DIR/install.log"
mkdir -p "$APP_DIR"
exec > >(tee -a "$LOG") 2>&1
echo "---- 安装开始 $(date '+%Y-%m-%d %H:%M:%S') ----"

step() { printf '\n\033[36m>> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m   OK: %s\033[0m\n' "$1"; }
# 出错时把日志末尾放进剪贴板：用户不会找文件，但会「粘贴」。只取最后 200 行，
# 重跑多次之后全量粘进聊天窗口会卡。sleep 是等 tee 把最后几行落盘——它是异步的。
die()  {
  printf '\n\033[31m[X] %s\033[0m\n检查一下网络（GitHub 要能访问），然后重跑安装命令。\n' "$1"
  sleep 0.5
  if [ -f "$LOG" ] && tail -n 200 "$LOG" | pbcopy 2>/dev/null; then
    printf '\n\033[33m  出错了。错误信息已经复制到剪贴板，直接粘贴给站长就行。\033[0m\n\n'
  else
    printf '\n\033[33m  出错了。日志在 %s，把这个文件发给站长。\033[0m\n\n' "$LOG"
  fi
  exit 1
}

echo "=============================================="
echo "  群星回廊 · 本地啃书翻译器 安装程序 (macOS)"
echo "  不动系统、不要密码，全装在你自己目录里"
echo "=============================================="

ARCH="$(uname -m)"   # arm64 (M 系芯片) 或 x86_64 (Intel)
mkdir -p "$APP_DIR" "$BIN_DIR" "$HOME/Applications"

# ---------------------------------------------------------------- Node
step "安装 Node（网页程序的运行环境）"
if [ ! -x "$NODE_DIR/bin/node" ]; then
  # 先问阿里云 npmmirror（国内快且没被墙）。它那个 latest-v22.x/ 目录列的是**所有** v22 版本，
  # 不是最新那个——得自己挑最大的，还得 >= 22.15（dsh 的门槛）。macOS 的 sort 没有 -V，按三段数字排。
  NODE_BASE="https://registry.npmmirror.com/-/binary/node/latest-v22.x"
  NODE_VER=$(curl -fsSL --connect-timeout 25 "$NODE_BASE/" 2>/dev/null \
    | grep -o "node-v22\.[0-9]*\.[0-9]*-darwin-$ARCH\.tar\.gz" | sed -E 's/node-v([0-9.]+)-darwin.*/\1/' \
    | sort -t. -k1,1n -k2,2n -k3,3n | awk -F. '$2>=15' | tail -1)
  if [ -n "$NODE_VER" ]; then
    NODE_TGZ="node-v$NODE_VER-darwin-$ARCH.tar.gz"
  else
    NODE_BASE="https://nodejs.org/dist/latest-v22.x"
    NODE_TGZ=$(curl -fsSL "$NODE_BASE/" | grep -o "node-v[0-9.]*-darwin-$ARCH.tar.gz" | head -1)
  fi
  [ -n "$NODE_TGZ" ] || die "问不到运行环境的下载地址"
  echo "   下载 $NODE_TGZ ..."
  curl -fL --progress-bar "$NODE_BASE/$NODE_TGZ" -o /tmp/shufang-node.tgz \
    || curl -fL --progress-bar "https://nodejs.org/dist/latest-v22.x/$NODE_TGZ" -o /tmp/shufang-node.tgz \
    || die "运行环境没下下来"
  rm -rf "$NODE_DIR" /tmp/shufang-node
  mkdir -p /tmp/shufang-node
  tar -xzf /tmp/shufang-node.tgz -C /tmp/shufang-node || die "运行环境的文件打不开，多半是没下完"
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
  [ -n "$PANDOC_URL" ] || die "问不到格式转换工具的下载地址"
  # GitHub 直连不通就走 gh-proxy.com 反代（原始地址整个跟在后面，2026-09 实测 800KB/s）
  curl -fL --progress-bar "$PANDOC_URL" -o /tmp/shufang-pandoc.zip \
    || curl -fL --progress-bar "https://gh-proxy.com/$PANDOC_URL" -o /tmp/shufang-pandoc.zip || die "格式转换工具没下下来"
  rm -rf /tmp/shufang-pandoc
  unzip -qo /tmp/shufang-pandoc.zip -d /tmp/shufang-pandoc || die "格式转换工具的文件打不开，多半是没下完"
  find /tmp/shufang-pandoc -type f -name pandoc -exec cp {} "$BIN_DIR/pandoc" \;
  chmod +x "$BIN_DIR/pandoc"
  rm -rf /tmp/shufang-pandoc.zip /tmp/shufang-pandoc
fi
ok "Pandoc 就绪"

# ---------------------------------------------------------------- Obsidian
# 译文是机器翻的，一定有要改的地方，而 Obsidian 读写的就是书库里那批 .md，
# 改完这边立刻看得到。所以它是默认装的一环，不是可选配件。
# 但装不上绝不能让整个安装失败——群星回廊自带网页界面，照样能看能改。
HAS_OBSIDIAN=0
if [ -d "/Applications/Obsidian.app" ] || [ -d "$HOME/Applications/Obsidian.app" ]; then
  HAS_OBSIDIAN=1
  ok "已装过 Obsidian"
else
  echo ""
  step "安装 Obsidian（用来自己改译文、做笔记）"
  printf '\033[90m   要下载 218MB。网不好可以按 n 跳过，以后重跑安装器随时能补。\033[0m\n'
  printf '   现在装吗 (Y/n): '
  read -r WANT_OBS </dev/tty
  if [[ "$WANT_OBS" =~ ^[Nn] ]]; then
    printf '\033[90m   跳过了。网页界面照常能看能改。\033[0m\n'
  else
    install_obsidian() {
      local dmg_url mnt
      # 资产名是 Obsidian-<版本>.dmg。原来这里写死找 universal.dmg，
      # 而人家早就不叫这个了——grep 永远空手而归，这一步等于从来没成功过。
      # 别用 releases/latest：2026-09 起上游把「最新」挂成了只带安卓 apk 的发布，
      # 桌面安装包在前一个发布里。翻最近几个，第一个 dmg 就是它。
      dmg_url=$(curl -fsSL "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=8" \
        | grep -o 'https://[^"]*/Obsidian-[0-9.]*\.dmg' | head -1)
      [ -n "$dmg_url" ] || return 1
      # GitHub 直连不通就走 gh-proxy.com 反代（原始地址整个跟在后面）
      curl -fL --progress-bar "$dmg_url" -o /tmp/shufang-obsidian.dmg \
        || curl -fL --progress-bar "https://gh-proxy.com/$dmg_url" -o /tmp/shufang-obsidian.dmg || return 1
      mnt=$(hdiutil attach -nobrowse -readonly /tmp/shufang-obsidian.dmg | grep -o '/Volumes/.*' | head -1)
      [ -n "$mnt" ] || return 1
      mkdir -p "$HOME/Applications"
      cp -R "$mnt/Obsidian.app" "$HOME/Applications/" || { hdiutil detach "$mnt" >/dev/null 2>&1; return 1; }
      hdiutil detach "$mnt" >/dev/null 2>&1
      rm -f /tmp/shufang-obsidian.dmg
      # 先启动一次，让系统记住 obsidian:// 链接归它管
      open -a "$HOME/Applications/Obsidian.app" --hide 2>/dev/null || true
      return 0
    }
    if install_obsidian; then
      HAS_OBSIDIAN=1
      ok "Obsidian 装好了"
    else
      printf '\033[33m   Obsidian 没装成，跳过（不影响用网页界面）。联网之后重新运行一次这个安装器就能补上。\033[0m\n'
      rm -f /tmp/shufang-obsidian.dmg
    fi
  fi
fi

# ---------------------------------------------------------------- dsh（DeepSeek Harness）
step "安装 dsh（翻译助手的大脑，DeepSeek 官方）"
if [ ! -x "$NODE_DIR/bin/dsh" ]; then
  # 先走阿里云 npmmirror，失败退回官方。只在这一条命令上带 --registry，不动用户的 ~/.npmrc。
  "$NODE_DIR/bin/npm" install -g @deepseek-ai/dsh --registry=https://registry.npmmirror.com \
    || "$NODE_DIR/bin/npm" install -g @deepseek-ai/dsh || die "翻译助手的大脑没装上，两个下载源都没成"
fi
ok "dsh 就绪"

# ---------------------------------------------------------------- PDF 支持
step "检查 PDF 支持"
if command -v python3 >/dev/null 2>&1; then
  # 版本钉死，理由同 Windows：新版 import 时硬拉 onnxruntime，容易整个崩掉
  if python3 -m pip install --quiet --user "pymupdf4llm==0.0.27" 2>/dev/null; then
    ok "PDF 支持就绪"
    # 扫描版 PDF（认字）。老书、影印本几乎全是「每一页都是图片」的 PDF，
    # 抽不出文字层。单问一句而不是默默装：这一步要下将近 100 MB，
    # 不读扫描件的人根本用不上。装不上也只是没有这一项，正常 PDF 不受影响。
    printf '   要支持扫描版 PDF 吗？需要再下约 100 MB (y/N) '
    read -r WANT_OCR </dev/tty
    case "$WANT_OCR" in
      [Yy]*)
        echo "   正在装认字组件（大约 100 MB，慢的话请耐心等）..."
        # 版本钉死，理由见 install.ps1 里同一处：它依赖 onnxruntime，
        # 而这个项目被 onnxruntime 的 DLL load failed 坑过。不钉的话
        # 今天装能跑、过几个月新装的人可能拉到起不来的那一版。
        if python3 -m pip install --quiet --user "rapidocr-onnxruntime==1.4.4" 2>/dev/null \
           && python3 -c "import rapidocr_onnxruntime" 2>/dev/null; then
          ok "扫描版 PDF 也能读了"
        else
          printf '\033[33m   认字组件没装成，扫描版 PDF 暂时读不了（普通 PDF 不受影响）。\033[0m\n'
          printf '\033[33m   想补上：联网之后重新运行一次这个安装器，这一步再选一次 y。\033[0m\n'
        fi
        ;;
      *) echo "   跳过了。以后想读扫描版的书，重跑一次本安装器，这一步选 y 就行。" ;;
    esac
  else
    printf '\033[33m   读 PDF 要用的东西没装上，PDF 格式的书暂时读不了（epub/txt/docx 不受影响）。\033[0m\n'
    printf '\033[33m   想补上：联网之后重新运行一次这个安装器。\033[0m\n'
  fi
else
  printf '\033[33m   这台电脑没装 Python，PDF 格式的书暂时读不了（epub/txt/docx 不受影响）。\033[0m\n'
  printf '\033[33m   想读 PDF：去 python.org 装一个 Python，再重新运行一次这个安装器就行。\033[0m\n'
fi

# 粘 API key 时带进来的脏东西比想象中多：网页上复制会捎上不断行空格、零宽字符、方向标记、BOM；
# 中文输入法开着全角会把 sk- 打成「ｓｋ－」；手动跨行选中会夹一个换行；有人连两边的引号一起复制走。
# 用户自己看不见——屏幕上就是一串正常的 key——所以先尽力洗干净再判，别只甩一句「格式不对」。
# 用 node 洗：上面刚装好，一定在；洗法跟 webapp/server.js 的 normalizeKey 保持一致。
# 不用 python3：macOS 上 /usr/bin/python3 可能只是个占位，一跑会弹「安装开发者工具」。
clean_key() {
  if [ -x "$NODE_DIR/bin/node" ]; then
    printf '%s' "$1" | "$NODE_DIR/bin/node" -e '
let s = require("fs").readFileSync(0, "utf8");
s = s.replace(/[\u200B-\u200F\u2028\u2029\u2060\uFEFF]/g, "");
s = s.replace(/[\uFF01-\uFF5E]/g, c => String.fromCharCode(c.charCodeAt(0) - 0xFEE0));
s = s.replace(/[\u2010-\u2015\u2212\u30FC]/g, "-");
s = s.replace(/\s+/g, "");
s = s.replace(/^["\u2018\u201C`\u300C\u300E\u300A]+/, "");
s = s.replace(/["\u2019\u201D`\u300D\u300F\u300B]+$/, "");
process.stdout.write(s);
'
  else
    printf '%s' "$1" | tr -d '[:space:]'
  fi
}

# ---------------------------------------------------------------- API key
step "配置 DeepSeek"
echo "   需要一个 DeepSeek API key（在 platform.deepseek.com 注册后创建，sk- 开头）。"
echo "   粘贴时屏幕上不会显示，这是正常的——粘完直接回车。"
KEY="$OLD_KEY"
[ -n "$KEY" ] && ok "沿用你上次填的 key（想换：删掉 $CONFIG 再装一遍）"
KEY_TRIES=0
while [[ ! "$KEY" =~ ^(sk-|enc:v1:) ]]; do
  KEY_TRIES=$((KEY_TRIES + 1))
  printf '   粘贴你的 DeepSeek API key: '
  if [ "$KEY_TRIES" -eq 1 ]; then
    # -s 不回显：整个安装过程在 tee 抄录日志，key 绝不能落进 /tmp/shufang-install.log
    read -rs KEY </dev/tty
    echo ""
  else
    # 有用户反馈：往不回显的输入里粘贴只进去一个字符，最后只能一个个手打。
    # 屏幕上什么都不显示，人根本看不出粘漏了。第二次起改成回显，粘完自己能看见对不对。
    # 代价是 key 会出现在屏幕和日志里——两害相权，装不上更糟。
    read -r KEY </dev/tty
  fi
  KEY="$(clean_key "$KEY")"
  if [[ ! "$KEY" =~ ^sk- ]]; then
    if [ -z "$KEY" ]; then
      echo "   什么都没粘进来。用 Cmd+V 粘贴，再回车。"
    elif [ ${#KEY} -lt 12 ]; then
      echo "   只读到 ${#KEY} 个字符——粘贴多半没进去全。下一次会把输入显示出来。"
    else
      echo "   这串是「$(printf '%.8s' "$KEY")…」开头的，不是 sk-。DeepSeek 的 key 一定 sk- 开头——是不是复制到别的东西了？"
    fi
  fi
done

# ---------------------------------------------------------------- 程序本体
step "获取群星回廊程序（之后每次启动自动检查更新）"
fetch_app() {
  local sha ver from_mirror
  # sha 和包必须来自同一个 commit。.app-sha 记的是「现在装的是哪一版」，
  # 记错了下次启动的更新器会拿它跟远端比，比出「已是最新」，用户就永远停在旧版，
  # 而且没有任何提示。所以：国内源的 version.json 通了 → 包也走国内源；
  # 包没下下来 → 回 codeload，并且把 sha 也重新从 GitHub 问一次（两边可能差一个 commit）。
  from_mirror=0
  ver=$(curl -fsSL --max-time 8 "$MIRROR/version.json" 2>/dev/null)
  sha=$(printf '%s' "$ver" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
  if [ -n "$sha" ]; then
    if curl -fsSL --max-time 120 "$MIRROR/shufang-master.tar.gz" -o /tmp/shufang-app.tgz; then
      from_mirror=1
    else
      echo "   国内源没通，改从 GitHub 拿"
      sha=""
    fi
  fi
  if [ "$from_mirror" = 0 ]; then
    sha=$(curl -fsSL "https://api.github.com/repos/$OWNER/$REPO/commits/master" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
    curl -fsSL "https://codeload.github.com/$OWNER/$REPO/tar.gz/master" -o /tmp/shufang-app.tgz || return 1
  fi
  rm -rf /tmp/shufang-app
  mkdir -p /tmp/shufang-app
  tar -xzf /tmp/shufang-app.tgz -C /tmp/shufang-app || return 1
  rm -rf "$APP_REPO"
  mv /tmp/shufang-app/"$REPO"-master "$APP_REPO"
  [ -n "$sha" ] && printf '%s' "$sha" > "$APP_DIR/.app-sha"
  rm -rf /tmp/shufang-app.tgz /tmp/shufang-app
}
fetch_app || die "群星回廊本体没下下来"
ok "已获取最新版"

if [ -d "$VAULT" ]; then
  ok "书库已存在（${VAULT}），保留原样"
else
  cp -R "$APP_REPO/vault-template" "$VAULT"
  ok "书库建在 $VAULT"
fi

( cd "$APP_REPO/webapp" && "$NODE_DIR/bin/npm" install --omit=dev --silent ) || die "网页程序的组件没装齐，这样装出来是打不开的"
ok "网页程序就绪"

# /dev/urandom 在 macOS 上就是加密随机源，取 24 位十六进制
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
ok "配置写好了"

# ---------------------------------------------------------------- 启动器
step "创建桌面启动器"
LAUNCHER="$HOME/Desktop/启动群星回廊.command"
cat > "$LAUNCHER" <<'LAUNCH_EOF'
#!/bin/bash
APP_DIR="$HOME/.shufang"
APP_REPO="$APP_DIR/app"
VAULT="$HOME/Documents/书房"
export PATH="$APP_DIR/node/bin:$APP_DIR/bin:$PATH"

# 检查更新：远端 commit 变了才重新下载（约 300KB），没变秒过。
# 版本号先问国内源（download.gnosaria.com，国内可达），问不到再问 GitHub。
echo "检查更新中..."
MIRROR="https://download.gnosaria.com/shufang"
FROM_MIRROR=0
LATEST=$(curl -fsSL --max-time 8 "$MIRROR/version.json" 2>/dev/null \
  | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
if [ -n "$LATEST" ]; then
  FROM_MIRROR=1
else
  LATEST=$(curl -fsSL --max-time 8 "https://api.github.com/repos/URaux/shufang/commits/master" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
fi
CURRENT=$(cat "$APP_DIR/.app-sha" 2>/dev/null || true)
if [ -n "$LATEST" ] && [ "$LATEST" != "$CURRENT" ]; then
  echo "发现新版本，更新中..."
  # sha 和包必须是同一个 commit：$LATEST 待会要写进 .app-sha，
  # 写了跟实际装的包对不上的 sha，下次启动就比出「已是最新」，用户永远卡在这一版。
  # 所以版本号哪来的、包就哪来的；国内源的包没拿到才回 GitHub，回退时 sha 也重新问一次。
  GOT=0
  if [ "$FROM_MIRROR" = 1 ]; then
    if curl -fsSL --max-time 60 "$MIRROR/shufang-master.tar.gz" -o /tmp/shufang-up.tgz; then
      GOT=1
    else
      echo "国内源没通，改从 GitHub 拿"
      LATEST=$(curl -fsSL --max-time 8 "https://api.github.com/repos/URaux/shufang/commits/master" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
    fi
  fi
  if [ "$GOT" = 0 ] && [ -n "$LATEST" ] \
     && curl -fsSL --max-time 60 "https://codeload.github.com/URaux/shufang/tar.gz/master" -o /tmp/shufang-up.tgz; then
    GOT=1
  fi
  if [ "$GOT" = 1 ]; then
    rm -rf /tmp/shufang-up && mkdir -p /tmp/shufang-up
    if tar -xzf /tmp/shufang-up.tgz -C /tmp/shufang-up 2>/dev/null && [ -d /tmp/shufang-up/shufang-master ]; then
      # 先把旧版挪到旁边再换新的，中途失败还能滚回来
      rm -rf "$APP_DIR/app.old"
      mv "$APP_REPO" "$APP_DIR/app.old" 2>/dev/null
      if mv /tmp/shufang-up/shufang-master "$APP_REPO"; then
        # node_modules 不在仓库里，从旧版搬过来，省一次 npm install
        if [ -d "$APP_DIR/app.old/webapp/node_modules" ] && [ ! -d "$APP_REPO/webapp/node_modules" ]; then
          mv "$APP_DIR/app.old/webapp/node_modules" "$APP_REPO/webapp/node_modules"
        fi
        printf '%s' "$LATEST" > "$APP_DIR/.app-sha"
        ( cd "$APP_REPO/webapp" && npm install --omit=dev --silent >/dev/null 2>&1 )
        # 同步助手的说明书到书库（你自己的书和笔记不会被动）
        cp -R "$APP_REPO/vault-template/.claude" "$VAULT/" 2>/dev/null
        cp "$APP_REPO/vault-template/CLAUDE.md" "$VAULT/" 2>/dev/null
        rm -rf "$APP_DIR/app.old"
        echo "已更新到最新版。"
      else
        mv "$APP_DIR/app.old" "$APP_REPO" 2>/dev/null
        echo "更新失败，继续用当前版本。"
      fi
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
# 装了 Obsidian 才唤起；没装就只开网页界面
if [ -d "/Applications/Obsidian.app" ] || [ -d "$HOME/Applications/Obsidian.app" ]; then
  open "obsidian://open?path=$(urlencode "$VAULT")" 2>/dev/null || open -a Obsidian 2>/dev/null || true
fi
( sleep 2; open "http://localhost:7787/" ) &
cd "$APP_REPO/webapp" || exit 1
# 服务输出同时落到 ~/.shufang/app.log：起不来的时候（Node 版本、缺模块、端口全占）
# 终端窗口一关线索就没了。追加写；超过 1MB 挪成 app.log.old，别让它无限长。
LOG="$APP_DIR/app.log"
if [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then mv -f "$LOG" "$LOG.old"; fi
echo "==== start $(date '+%Y-%m-%d %H:%M:%S') ====" >> "$LOG"
node server.js 2>&1 | tee -a "$LOG"
LAUNCH_EOF
chmod +x "$LAUNCHER"
ok "桌面上有「启动群星回廊.command」了"

# 「复制群星回廊日志.command」：装好了但起不来的时候，用户唯一做得到的事。
# 双击一下就把 install.log + app.log 的末尾放进剪贴板，弹一句「粘贴给站长」。
# 日志固定在 ~/.shufang，不随安装位置走，所以这个文件不用烤任何路径进去。
COPYLOG="$HOME/Desktop/复制群星回廊日志.command"
cat > "$COPYLOG" <<'COPY_EOF'
#!/bin/bash
# 各取最后 200 行：日志可能几兆，整个粘进聊天窗口会卡死。
D="$HOME/.shufang"
{
  found=0
  for f in install.log app.log; do
    if [ -f "$D/$f" ]; then found=1; echo "===== $f ====="; tail -n 200 "$D/$f"; fi
  done
  [ "$found" = 1 ] || echo "(没有找到日志文件：$D 里没有 install.log 和 app.log)"
} | pbcopy
osascript -e 'display dialog "日志已复制到剪贴板，粘贴给站长即可" buttons {"好"} default button 1 with title "群星回廊"' >/dev/null 2>&1 \
  || echo "日志已复制到剪贴板，粘贴给站长即可"
COPY_EOF
chmod +x "$COPYLOG"
xattr -d com.apple.quarantine "$COPYLOG" 2>/dev/null || true
ok "桌面上有「复制群星回廊日志.command」了（出问题时用）"

echo ""
echo "=============================================="
echo "  安装完成！"
echo "  双击桌面「启动群星回廊.command」开始用。"
echo "  第一次系统若拦截，右键它选「打开」一次即可。"
if [ "$HAS_OBSIDIAN" = "1" ]; then
  echo "  第一次 Obsidian 打开时选「信任此仓库」。"
fi
echo "=============================================="
echo "  如果之后启动出问题，双击桌面的『复制群星回廊日志』就能把日志复制到剪贴板。"
