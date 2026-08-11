@echo off
chcp 65001 >nul
title 书房安装器
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
