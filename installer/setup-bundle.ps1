# 群星阅览室 全量包安装器 —— 零下载、零依赖，全部东西都在包里。
# 给卡在网络问题上的用户：解压后双击「一键安装.bat」跑到这里。
# 支持自选安装位置（C 盘满了的人装 D 盘）。
# 也可以带参数静默安装（帮别人远程装机用）：
#   powershell -File setup-bundle.ps1 -InstallDir D:\群星阅览室 -VaultDir D:\书库 -ApiKey sk-xxx
param(
  [string]$InstallDir = "",
  [string]$VaultDir = "",
  [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { chcp 65001 > $null } catch {}
$LogPath = Join-Path $env:TEMP "shufang-install.log"
try { Start-Transcript -Path $LogPath -Force | Out-Null } catch {}

trap {
  Write-Host ""
  Write-Host "[X] 安装中途出错了: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "    日志在 $LogPath，可以把它发给帮你装的人。" -ForegroundColor Yellow
  try { Stop-Transcript | Out-Null } catch {}
  Read-Host "按回车关闭"
  exit 1
}

$Payload = Join-Path $PSScriptRoot "payload"
if (-not (Test-Path (Join-Path $Payload "node\node.exe"))) {
  Write-Host "[X] 找不到安装材料（payload 文件夹）。" -ForegroundColor Red
  Write-Host "    你可能是在压缩包里面直接双击的——先把整个压缩包解压出来，再运行。" -ForegroundColor Yellow
  Read-Host "按回车关闭"
  exit 1
}

function Step($m) { Write-Host ""; Write-Host ">> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   OK: $m" -ForegroundColor Green }

Write-Host "=============================================="
Write-Host "  群星阅览室 · 全量包安装"
Write-Host "  所有东西都在包里，不用下载、不要管理员"
Write-Host "=============================================="

# ---------------------------------------------------------------- 位置选择
$DefaultApp = Join-Path $env:USERPROFILE ".shufang"
if ($InstallDir) {
  $AppDir = $InstallDir
} else {
  Write-Host ""
  Write-Host "程序装到哪？（程序本体 + 运行环境，约 700MB）"
  Write-Host "直接回车用默认: $DefaultApp"
  Write-Host "C 盘不够就输入别的地方，比如 D:\群星阅览室"
  $AppDir = (Read-Host "安装位置").Trim().Trim('"')
  if (-not $AppDir) { $AppDir = $DefaultApp }
}
if ($AppDir -match '[\u4e00-\u9fff]') {
  # 中文路径本身没问题，但个别 npm 包对非 ASCII cwd 犯病，提示一句不拦着
  Write-Host "   （路径带中文一般没事，万一之后出怪问题可以换成纯英文路径重装）" -ForegroundColor DarkGray
}
New-Item -ItemType Directory -Force $AppDir | Out-Null

$DefaultVault = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "书房"
if ($VaultDir) {
  $Vault = $VaultDir
} else {
  Write-Host ""
  Write-Host "书库放到哪？（你的书、译文、笔记都在这，会越来越大）"
  Write-Host "直接回车用默认: $DefaultVault"
  $Vault = (Read-Host "书库位置").Trim().Trim('"')
  if (-not $Vault) { $Vault = $DefaultVault }
}

# 配置文件固定在 ~\.shufang（几 KB，程序按这个位置找配置；大东西都在你选的地方）
$ConfigDir = Join-Path $env:USERPROFILE ".shufang"
$ConfigPath = Join-Path $ConfigDir "config.json"
New-Item -ItemType Directory -Force $ConfigDir | Out-Null

$NodeDir = Join-Path $AppDir "node"
$BinDir  = Join-Path $AppDir "bin"
$AppRepo = Join-Path $AppDir "app"

# ---------------------------------------------------------------- 落料
Step "安放运行环境（Node + Pandoc + Claude Code，已内置）"
foreach ($piece in @("node", "bin")) {
  $dest = Join-Path $AppDir $piece
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  Copy-Item (Join-Path $Payload $piece) $dest -Recurse
}
Ok "运行环境就绪（$NodeDir）"

Step "安放程序本体"
if (Test-Path $AppRepo) { Remove-Item -Recurse -Force $AppRepo }
Copy-Item (Join-Path $Payload "app") $AppRepo -Recurse
Ok "程序就绪（$AppRepo）"

Step "建书库"
if (Test-Path $Vault) {
  Ok "书库已存在（$Vault），保留原样"
} else {
  Copy-Item -Recurse (Join-Path $AppRepo "vault-template") $Vault
  Ok "书库建在 $Vault"
}

# ---------------------------------------------------------------- API key
try { Stop-Transcript | Out-Null } catch {}
Step "配置 DeepSeek"
if ($ApiKey -match "^sk-") {
  $key = $ApiKey
} else {
  Write-Host "   需要一个 DeepSeek API key（在 platform.deepseek.com 注册后创建，sk- 开头）。"
  Write-Host "   粘贴时屏幕上不会显示，这是正常的——粘完直接回车。" -ForegroundColor DarkGray
  $key = ""
  while (-not ($key -match "^sk-")) {
    $sec  = Read-Host "   粘贴你的 DeepSeek API key" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $key = ([Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not ($key -match "^sk-")) { Write-Host "   看起来不太对，应该是 sk- 开头的一串。再试一次。" -ForegroundColor Yellow }
  }
}

$tokenBytes = New-Object byte[] 16
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($tokenBytes) } finally { $rng.Dispose() }
$token = -join ($tokenBytes | ForEach-Object { $_.ToString("x2") })

$config = [ordered]@{
  vaultPath = $Vault
  port      = 7787
  token     = $token
  env       = [ordered]@{
    ANTHROPIC_BASE_URL              = "https://api.deepseek.com/anthropic"
    ANTHROPIC_AUTH_TOKEN            = $key
    ANTHROPIC_MODEL                 = "deepseek-v4-pro"
    ANTHROPIC_DEFAULT_OPUS_MODEL    = "deepseek-v4-pro"
    ANTHROPIC_DEFAULT_SONNET_MODEL  = "deepseek-v4-flash"
    ANTHROPIC_DEFAULT_HAIKU_MODEL   = "deepseek-v4-flash"
    CLAUDE_CODE_SUBAGENT_MODEL      = "deepseek-v4-flash"
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
  }
}
# 无 BOM UTF-8：server.js 的 JSON.parse 见到 BOM 会当首次运行，key 就"丢"了
[System.IO.File]::WriteAllText($ConfigPath, ($config | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
$key = $null
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch {}
Ok "配置写好了"

# ---------------------------------------------------------------- 自动更新器（有网时用，没网静默跳过）
Step "安装自动更新器"
$Owner = "URaux"; $Repo = "shufang"
$UpdaterPath = Join-Path $AppDir "update.ps1"
$updaterText = @"
`$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
`$AppDir  = "$AppDir"
`$AppRepo = "$AppRepo"
`$ShaFile = Join-Path `$AppDir ".app-sha"
try {
  `$latest = ((curl.exe -fsSL --max-time 10 -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$Owner/$Repo/commits/master") -join "").Trim()
  if (`$latest -notmatch '^[0-9a-f]{40}$') { return }
  if (-not `$latest) { return }
  `$current = ""
  if (Test-Path `$ShaFile) { `$current = (Get-Content `$ShaFile -Raw).Trim() }
  if (`$latest -eq `$current) { Write-Host "已是最新版" -ForegroundColor DarkGray; return }
  Write-Host "发现新版本，更新中..." -ForegroundColor Cyan
  `$zip = Join-Path `$env:TEMP "sf-up.zip"
  `$tmp = Join-Path `$env:TEMP "sf-up"
  curl.exe -fsSL --max-time 120 -o "`$zip" "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/master"
  if (`$LASTEXITCODE -ne 0) { return }
  if (Test-Path `$tmp) { Remove-Item -Recurse -Force `$tmp }
  # 用 zip + Expand-Archive：仓库有中文文件名，tar.exe 解 tar.gz 会炸
  Expand-Archive -Path `$zip -DestinationPath `$tmp -Force
  `$inner = Get-ChildItem `$tmp -Directory | Select-Object -First 1
  if (-not `$inner) { return }
  `$backup = Join-Path `$AppDir "app.old"
  if (Test-Path `$backup) { Remove-Item -Recurse -Force `$backup }
  if (Test-Path `$AppRepo) { Move-Item `$AppRepo `$backup }
  try {
    Move-Item `$inner.FullName `$AppRepo
    `$oldMods = Join-Path `$backup "webapp\node_modules"
    `$newMods = Join-Path `$AppRepo "webapp\node_modules"
    if ((Test-Path `$oldMods) -and (-not (Test-Path `$newMods))) { Move-Item `$oldMods `$newMods }
    Set-Content -Path `$ShaFile -Value `$latest -NoNewline
    Remove-Item -Recurse -Force `$backup -ErrorAction SilentlyContinue
    Write-Host "更新完成" -ForegroundColor Green
  } catch {
    if (Test-Path `$AppRepo) { Remove-Item -Recurse -Force `$AppRepo -ErrorAction SilentlyContinue }
    if (Test-Path `$backup) { Move-Item `$backup `$AppRepo }
    Write-Host "更新失败，继续用当前版本" -ForegroundColor Yellow
  }
  Remove-Item -Recurse -Force `$zip, `$tmp -ErrorAction SilentlyContinue
} catch {
  Write-Host "检查更新时出了点问题，跳过，直接启动。" -ForegroundColor DarkGray
}
"@
[System.IO.File]::WriteAllText($UpdaterPath, $updaterText, (New-Object System.Text.UTF8Encoding($true)))
Ok "自动更新器就绪"

# ---------------------------------------------------------------- 桌面启动器
Step "创建桌面启动器"
$Desktop = [Environment]::GetFolderPath("Desktop")
$launcher = Join-Path $Desktop "启动群星阅览室.bat"
$launcherText = @"
@echo off
chcp 65001 >nul
title 群星阅览室
set "PATH=$NodeDir;$BinDir;%PATH%"
echo 检查更新中...
powershell -NoProfile -ExecutionPolicy Bypass -File "$UpdaterPath"
cd /d "$AppRepo\webapp"
if not exist node_modules (
  echo 首次安装依赖，稍等...
  call "$NodeDir\npm.cmd" install --omit=dev --silent
)
rem 全量包默认没装 Obsidian，装了的话取消下一行的 rem 即可
rem start "" "obsidian://open?path=$([uri]::EscapeDataString($Vault))"
start "" http://localhost:7787/
node server.js
pause
"@
[System.IO.File]::WriteAllText($launcher, $launcherText, (New-Object System.Text.UTF8Encoding($false)))
Ok "桌面上有「启动群星阅览室」了"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "  程序在: $AppDir" -ForegroundColor Green
Write-Host "  书库在: $Vault" -ForegroundColor Green
Write-Host "  双击桌面「启动群星阅览室」开始用。" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
if (-not ($InstallDir -and $ApiKey)) { Read-Host "按回车关闭本窗口" }
