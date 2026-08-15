#!/bin/bash
# 群星阅览室 Mac 一键安装引导器。
# 第一次双击若被系统拦（“无法打开，因为它来自身份不明的开发者”），
# 右键点它选「打开」，再点一次「打开」即可。
clear
echo "=============================================="
echo "  群星阅览室 · 安装引导"
echo "=============================================="
echo ""
echo "正在获取最新安装程序..."
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/URaux/shufang/master/installer/install-mac.sh)" || {
  echo ""
  echo "[!] 没下载到安装程序。检查一下网络（要能访问 GitHub），然后重新运行本文件。"
  read -r -p "按回车关闭"
}
