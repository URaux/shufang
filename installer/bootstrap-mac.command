#!/bin/bash
# 群星回廊 Mac 一键安装引导器。
# 第一次双击若被系统拦（“无法打开，因为它来自身份不明的开发者”），
# 右键点它选「打开」，再点一次「打开」即可。
clear
echo "=============================================="
echo "  群星回廊 · 安装引导"
echo "=============================================="
echo ""
echo "正在获取最新安装程序..."
# 先把脚本拿到手、再跑，两步分开。原来是一句 bash -c "$(curl ...)" || 报「没下载到」，
# 于是安装器本身失败也被说成没下载到，用户照着去查网络，白查。
SCRIPT="$(curl -fsSL --max-time 20 https://raw.githubusercontent.com/URaux/shufang/master/installer/install-mac.sh)"
# GitHub 拿不到就换国内源（同一份脚本，发布时同步上去的）
[ -n "$SCRIPT" ] || SCRIPT="$(curl -fsSL --max-time 30 https://download.gnosaria.com/shufang/install-mac.sh)"
if [ -z "$SCRIPT" ]; then
  echo ""
  echo "[!] 没下载到安装程序。两个下载源都没连上，检查一下网络，然后重新运行本文件。"
  read -r -p "按回车关闭"
  exit 1
fi
/bin/bash -c "$SCRIPT" || {
  # 安装器失败时自己已经把日志末尾放进剪贴板了；这儿再兜一次，
  # 防的是它在写日志之前就死掉（比如 ~/.shufang 建不出来）。
  echo ""
  LOG="$HOME/.shufang/install.log"
  if [ -f "$LOG" ] && tail -n 200 "$LOG" | pbcopy 2>/dev/null; then
    echo "出错了。错误信息已经复制到剪贴板，直接粘贴给站长就行。"
  else
    echo "[!] 安装没有完成。把屏幕上的内容截图发给站长。"
  fi
  read -r -p "按回车关闭"
}
