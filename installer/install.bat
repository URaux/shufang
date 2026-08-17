@echo off
chcp 65001 >nul
title 群星回廊安装器

rem 最常见的翻车：在压缩包预览里直接双击了 bat，此时 install.ps1 根本不在旁边
if not exist "%~dp0install.ps1" (
  echo.
  echo  [X] 找不到安装脚本 install.ps1
  echo.
  echo  你可能是在压缩包里面直接双击的。
  echo  请先把整个压缩包「解压」到桌面或任意文件夹，
  echo  再进解压出来的文件夹里双击 install.bat。
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if errorlevel 1 (
  echo.
  echo  [!] 安装没有完成。日志在: %TEMP%\shufang-install.log
  echo      可以把这个文件发给帮你装的人看。
)
pause
