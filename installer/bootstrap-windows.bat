@echo off
chcp 65001 >nul
title 群星回廊安装器
rem 自包含引导器：下载正式安装脚本再运行，单个文件双击即可，不需要旁边有别的文件。
rem 先 GitHub，拿不到换国内源 download.gnosaria.com（同一份脚本，发布时同步上去的）。
echo.
echo   正在获取最新安装程序...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $f=Join-Path $env:TEMP 'shufang-install.ps1'; try { Invoke-WebRequest 'https://raw.githubusercontent.com/URaux/shufang/master/installer/install.ps1' -OutFile $f -UseBasicParsing -TimeoutSec 20 } catch { Invoke-WebRequest 'https://download.gnosaria.com/shufang/install.ps1' -OutFile $f -UseBasicParsing -TimeoutSec 30 }; powershell -NoProfile -ExecutionPolicy Bypass -File $f"
if errorlevel 1 (
  echo.
  echo   [!] 没下载到安装程序。两个下载源都没连上，检查一下网络，然后重新双击本文件。
  pause
)
