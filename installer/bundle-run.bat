@echo off
chcp 65001 >nul
title 群星阅览室安装器
rem 全量包入口。放在解压出来的文件夹里双击。

if not exist "%~dp0setup-bundle.ps1" (
  echo.
  echo  [X] 找不到安装脚本。
  echo  你可能是在压缩包里面直接双击的。
  echo  请先把整个压缩包「解压」出来，再进解压出的文件夹里双击本文件。
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-bundle.ps1"
if errorlevel 1 (
  echo.
  echo  [!] 安装没有完成。日志在: %TEMP%\shufang-install.log
)
