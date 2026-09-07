# 打 Windows 全量安装包（单个 exe，双击就装，Node + dsh + Pandoc + 程序全在里面，零下载）。
#
# 为什么是 exe 不是 zip：给小白的下载页只能放一个「点一下」的东西。zip 要解压、要进文件夹、
# 要找那个 .bat——每一步都有人卡住。exe 双击 → 解开 → 自动拉起安装器，一步。
#
# 怎么封：Windows 自带的 IExpress。它把文件打进 CAB 自解压器，解开后跑一条命令。
# 没用 7-Zip / Inno / NSIS：这台机器上都没有，而 IExpress 每台 Windows 都有，包不出意外。
# IExpress 的 CAB 里文件是平铺的、不认目录，所以先把整包压成一个 bundle.zip 塞进去，
# 再配一个 run.bat 负责解压到 %TEMP% 并拉起 bundle-run.bat。
#
# 载荷从哪来：默认直接搬本机 ~\.shufang 下装好的 node（含 dsh）和 bin（pandoc）——
# 那是一套跑着的、版本对得上的运行环境；程序本体用 dist-build\（build-dist.js 刚打出来的产物，
# 跟分发仓 master 一字不差）。要换来源用参数。
#
# 用法（在源码仓根目录）：
#   powershell -File installer\build-win-bundle.ps1 -Version 0.8.0
# 产物：dist-bundle\shufang-v<版本>-win-full.exe
param(
  [string]$Version = "0.8.0",
  [string]$Node = (Join-Path $env:USERPROFILE ".shufang\node"),
  [string]$Bin  = (Join-Path $env:USERPROFILE ".shufang\bin"),
  [string]$App  = "",
  [switch]$SkipZip        # bundle.zip 已经打好、只想重封 exe 时用（打包要七八分钟）
)
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
if (-not $App) { $App = Join-Path $Root "dist-build" }
foreach ($p in @($Node, $Bin, $App)) { if (-not (Test-Path $p)) { throw "缺来源目录：$p" } }
if (-not (Test-Path (Join-Path $Node "node.exe"))) { throw "$Node 里没有 node.exe" }
if (-not (Test-Path (Join-Path $Node "node_modules\@deepseek-ai\dsh"))) { throw "$Node 里没有 dsh（node_modules\@deepseek-ai\dsh）" }
if (-not (Test-Path (Join-Path $Bin "pandoc.exe"))) { throw "$Bin 里没有 pandoc.exe" }
if (-not (Test-Path (Join-Path $App "webapp\server.js"))) { throw "$App 不像程序目录（没有 webapp\server.js）" }

$Stage = Join-Path $Root "dist-bundle"
$Pkg = Join-Path $Stage "pkg"
$Zip = Join-Path $Stage "bundle.zip"
if ($SkipZip -and (Test-Path $Zip)) {
  Write-Host ">> 跳过组包，用现成的 bundle.zip"
} else {
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $Pkg "payload") | Out-Null

Write-Host ">> 安装器文件"
foreach ($f in @("setup-bundle.ps1", "bundle-run.bat", "安装群星回廊.vbs", "logo.ico", "launcher-template.vbs", "copylog-template.vbs")) {
  Copy-Item (Join-Path $PSScriptRoot $f) $Pkg
}

# robocopy 而不是 Copy-Item：几万个小文件 Copy-Item 慢一个量级，而且路径里有非 ASCII 字符时
# Copy-Item -Recurse 偶发漏文件不报错。robocopy 退出码 0–7 都是成功。
function Mirror($from, $to, [string[]]$xd = @()) {
  $args = @($from, $to, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/R:2", "/W:1")
  if ($xd.Count) { $args += "/XD"; $args += $xd }
  & robocopy @args | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "拷贝失败（robocopy $LASTEXITCODE）：$from" }
}
Write-Host ">> 运行环境（Node + dsh）"
Mirror $Node (Join-Path $Pkg "payload\node")
Write-Host ">> Pandoc"
Mirror $Bin (Join-Path $Pkg "payload\bin")
Write-Host ">> 程序本体"
Mirror $App (Join-Path $Pkg "payload\app") @("node_modules", ".git")

# 清掉纯开发期的文件。两个理由，第二个是硬伤：
#   一、体积——三千多个 .map、四千多个 .d.ts，运行时一个都用不上；
#   二、路径长度——Windows 的 260 字符上限是按**全路径**算的。实测载荷里最长的相对路径 209 字符，
#      解到 %TEMP%\shufang-setup（前缀 55 字符）就是 264，正好越界。有用户就卡在这儿：
#      「安装中途出错了：未能找到路径 ...getchatcompletionfieldoptions...post.d.ts.map 的一部分」，
#      而且**装了一半**——dsh 的依赖没拷全，装完聊天永远起不来（ERR_MODULE_NOT_FOUND）。
#      名字最长的那批恰恰就是 .d.ts.map，删掉它们等于把最长的那截砍掉。
Write-Host ">> 清理载荷里的开发文件（.map / .d.ts）"
$before = (Get-ChildItem (Join-Path $Pkg "payload") -Recurse -File).Count
Get-ChildItem (Join-Path $Pkg "payload") -Recurse -File -Include *.map, *.d.ts -ErrorAction SilentlyContinue |
  Remove-Item -Force -ErrorAction SilentlyContinue
$after = (Get-ChildItem (Join-Path $Pkg "payload") -Recurse -File).Count
Write-Host "   删掉 $($before - $after) 个文件"
$longest = (Get-ChildItem (Join-Path $Pkg "payload") -Recurse -File |
            ForEach-Object { $_.FullName.Length - $Pkg.Length } | Measure-Object -Maximum).Maximum
Write-Host "   载荷里最长相对路径 $longest 字符（解压目录再长也不该超过 260）"

Write-Host ">> 压成 bundle.zip（几万个文件，要一两分钟）"
Compress-Archive -Path (Join-Path $Pkg "*") -DestinationPath $Zip -CompressionLevel Optimal
$zipMB = [math]::Round((Get-Item $Zip).Length / 1MB, 1)
Write-Host "   bundle.zip $zipMB MB"
}

# run.bat：只有 ASCII，别让 cmd 的代码页问题掺和进来。
# 解到盘根的 sf-setup 而不是 %TEMP%\shufang-setup：后者前缀就 55 个字符，
# 加上载荷里两百来字符的相对路径直接越过 Windows 的 260 上限，安装会半途而废。
# 解压用 Windows 自带的 tar.exe（libarchive）：三万五千个文件 16 秒；Expand-Archive 同一个包十分钟都解不完，
# 用户会以为死了。CLAUDE.md 里说 tar.exe 会炸的是 tar.gz 里的中文名；zip 的 UTF-8 文件名它认得好好的
# （实测「安装群星回廊.vbs」「怎么用群星回廊」原样出来）。没有 tar.exe 的老机器（Win10 1803 以前）退回 Expand-Archive。
$RunBat = Join-Path $Stage "run.bat"
$bat = @'
@echo off
setlocal
title Shufang Setup
set "T=%SystemDrive%\sf-setup"
if exist "%T%" rmdir /s /q "%T%"
mkdir "%T%"
echo Unpacking installer, please wait...
if exist "%WINDIR%\System32\tar.exe" (
  "%WINDIR%\System32\tar.exe" -xf "%~dp0bundle.zip" -C "%T%"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%~dp0bundle.zip' -DestinationPath '%T%' -Force"
)
if not exist "%T%\setup-bundle.ps1" (
  echo.
  echo Unpack failed. Check free space on C: drive, then run this installer again.
  pause
  exit /b 1
)
start "Shufang Setup" /D "%T%" powershell -NoProfile -ExecutionPolicy Bypass -File "%T%\setup-bundle.ps1"
'@
# 直接起 PowerShell，不经 bundle-run.bat：那个 .bat 是 UTF-8 + chcp 65001 + LF 行尾的组合，
# 从另一个 cmd 里 start 它时 `if not exist "%~dp0..."` 会误判成「找不到安装脚本」然后停在 pause
# （实测：记号只走到它第一行，安装器从没起来）。这条 run.bat 全 ASCII、CRLF，没有那些变数。
[IO.File]::WriteAllText($RunBat, $bat, [Text.Encoding]::ASCII)

Write-Host ">> IExpress 封 exe"
$Exe = Join-Path $Stage "shufang-v$Version-win-full.exe"
$Sed = Join-Path $Stage "bundle.sed"
$sedText = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$Exe
FriendlyName=群星回廊 安装器 v$Version
AppLaunched=cmd /c run.bat
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
FILE0="bundle.zip"
FILE1="run.bat"
[SourceFiles]
SourceFiles0=$Stage\
[SourceFiles0]
%FILE0%=
%FILE1%=
"@
# 变量名别跟 $Sed 撞：PowerShell 不分大小写，$sed 就是 $Sed，首跑时正文把路径盖掉了。
# SED 是 IExpress 按系统代码页读的，中文名得用 ANSI（GBK）存，UTF-8 会成乱码
[IO.File]::WriteAllText($Sed, $sedText, [Text.Encoding]::Default)
& "$env:WINDIR\System32\iexpress.exe" /N /Q $Sed
# iexpress 是 GUI 程序，/N /Q 之后立刻返回，得等它把 exe 写完
for ($i = 0; $i -lt 600; $i++) {
  Start-Sleep 1
  if ((Test-Path $Exe) -and -not (Get-Process iexpress -ErrorAction SilentlyContinue)) { break }
}
if (-not (Test-Path $Exe)) { throw "IExpress 没产出 exe（看 $Sed 和 IExpress 的弹窗）" }
$exeMB = [math]::Round((Get-Item $Exe).Length / 1MB, 1)
Write-Host ""
Write-Host "OK  $Exe  ($exeMB MB)" -ForegroundColor Green
