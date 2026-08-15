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

function RemoveWithRetry($path) {
  # Windows 关掉进程后文件句柄要过一会儿才释放，直接删常报「正在使用中」。
  for ($i = 1; $i -le 8; $i++) {
    if (-not (Test-Path $path)) { return }
    try { Remove-Item -Recurse -Force $path -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 600 }
  }
  # 还删不掉就改名让路，下次启动前清理
  try { Rename-Item $path "$path.old-$(Get-Random)" -ErrorAction Stop } catch {
    throw "有程序正占着 $path。请把所有群星阅览室窗口关掉（或重启电脑）后重新安装。"
  }
}


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
  $AppDir = ("" + (Read-Host "安装位置")).Trim().Trim('"')
  if (-not $AppDir) { $AppDir = $DefaultApp }
}
if ($AppDir -match '[\u4e00-\u9fff]') {
  # 中文路径本身没问题，但个别 npm 包对非 ASCII cwd 犯病，提示一句不拦着
  Write-Host "   （路径带中文一般没事，万一之后出怪问题可以换成纯英文路径重装）" -ForegroundColor DarkGray
}
New-Item -ItemType Directory -Force $AppDir | Out-Null

# ---------------------------------------------------------------- 读老配置
# 升级场景：key / token / 端口 / 书库位置都沿用，别让人重填一遍。
# token 尤其重要——它变了的话，手机上存的那个带 ?t= 的链接就全失效了。
$ConfigDir  = Join-Path $env:USERPROFILE ".shufang"
$ConfigPath = Join-Path $ConfigDir "config.json"
$OldCfg = $null
if (Test-Path $ConfigPath) {
  try {
    $__raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
    $OldCfg = ($__raw.TrimStart([char]0xFEFF)) | ConvertFrom-Json
  } catch { $OldCfg = $null }
}
$OldKey = ""
if ($OldCfg -and $OldCfg.env -and $OldCfg.env.DEEPSEEK_API_KEY) {
  $__k = [string]$OldCfg.env.DEEPSEEK_API_KEY
  # enc:v1: 是本机加密过的，照样能用，原样搬过去就行
  if ($__k -match "^(sk-|enc:v1:)") { $OldKey = $__k }
}
$OldVault = ""
if ($OldCfg -and $OldCfg.vaultPath -and (Test-Path $OldCfg.vaultPath)) { $OldVault = [string]$OldCfg.vaultPath }

$DefaultVault = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "书房"
if ($VaultDir) {
  $Vault = $VaultDir
} else {
  Write-Host ""
  Write-Host "书库放到哪？（你的书、译文、笔记都在这，会越来越大）"
  Write-Host "直接回车用默认: $DefaultVault"
  $Vault = ("" + (Read-Host "书库位置")).Trim().Trim('"')
  if (-not $Vault) { if ($OldVault) { $Vault = $OldVault } else { $Vault = $DefaultVault } }
}

# 配置文件固定在 ~\.shufang（几 KB，程序按这个位置找配置；大东西都在你选的地方）
$ConfigDir = Join-Path $env:USERPROFILE ".shufang"
New-Item -ItemType Directory -Force $ConfigDir | Out-Null

$NodeDir = Join-Path $AppDir "node"
$BinDir  = Join-Path $AppDir "bin"
$AppRepo = Join-Path $AppDir "app"

# ---------------------------------------------------------------- 先停掉在跑的实例
# 程序开着的时候装/重装，node.exe 正被占用，复制会「访问被拒绝」。
# 小白不知道要先关窗口，这里自动停一下。
Step "检查有没有正在运行的群星阅览室"
$stopped = 0
Get-Process node -ErrorAction SilentlyContinue | ForEach-Object {
  try {
    $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($cl -and ($cl -match "\.shufang" -or $cl -match "server\.js")) {
      Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
      $stopped++
    }
  } catch { }
}
if ($stopped -gt 0) { Start-Sleep -Seconds 2; Ok "已关掉 $stopped 个正在运行的窗口" } else { Ok "没有在运行的" }

# ---------------------------------------------------------------- 落料
Step "安放运行环境（Node + Pandoc + dsh，已内置）"
foreach ($piece in @("node", "bin")) {
  $dest = Join-Path $AppDir $piece
  RemoveWithRetry $dest
  Copy-Item (Join-Path $Payload $piece) $dest -Recurse
}
Ok "运行环境就绪（$NodeDir）"

Step "安放程序本体"
RemoveWithRetry $AppRepo
Copy-Item (Join-Path $Payload "app") $AppRepo -Recurse
Ok "程序就绪（$AppRepo）"

Step "建书库"
if (Test-Path $Vault) {
  Ok "书库已存在（$Vault），保留原样"
} else {
  Copy-Item -Recurse (Join-Path $AppRepo "vault-template") $Vault
  Ok "书库建在 $Vault"
}

# ---------------------------------------------------------------- PDF 支持
Step "检查 PDF 支持"
if (Get-Command python -ErrorAction SilentlyContinue) {
  # 版本必须钉死。pymupdf4llm 从 1.27 起 import 时就硬 import onnxruntime（自带 OCR），
  # 而 onnxruntime 在不少 Windows 机器上 DLL load failed —— 实测本机 1.22/1.28 都起不来，
  # 结果是 import 直接崩、PDF 支持静默消失，报错用户完全看不懂。0.0.27 不碰它。
  python -m pip install --quiet --user "pymupdf4llm==0.0.27" 2>$null
  Ok "PDF 支持就绪"
} else {
  Write-Host "   这台电脑没装 Python，PDF 格式的书暂时读不了（epub/txt/docx 不受影响）。" -ForegroundColor Yellow
  Write-Host "   想读 PDF：去 python.org 装一个 Python，再重跑一次本安装器就行。" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- API key
try { Stop-Transcript | Out-Null } catch {}
Step "配置 DeepSeek"
# 次序：命令行显式传的 > 上次存的 > 问用户。
# 反过来的话，用户想换 key 而特地带 -ApiKey 重装，会被老 key 默默盖掉。
if ($ApiKey -match "^sk-") {
  $key = $ApiKey
} elseif ($OldKey) {
  $key = $OldKey
  Ok "沿用你上次填的 key（想换成别的：删掉 $ConfigPath 再装一遍）"
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

# 老 token 留着——换了的话手机上存的链接就打不开了
$token = ""
if ($OldCfg -and $OldCfg.token) { $token = [string]$OldCfg.token }
if (-not $token) {
  $tokenBytes = New-Object byte[] 16
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($tokenBytes) } finally { $rng.Dispose() }
  $token = -join ($tokenBytes | ForEach-Object { $_.ToString("x2") })
}

# 在老配置上改，不是推倒重来：remoteAccess 这类设置都留着
$config = [ordered]@{}
if ($OldCfg) { foreach ($__p in $OldCfg.PSObject.Properties) { $config[$__p.Name] = $__p.Value } }
$__env = [ordered]@{}
if ($OldCfg -and $OldCfg.env) { foreach ($__p in $OldCfg.env.PSObject.Properties) { $__env[$__p.Name] = $__p.Value } }
$__env["DEEPSEEK_API_KEY"] = $key
$config["vaultPath"] = $Vault
if (-not $config["port"]) { $config["port"] = 7787 }
$config["token"] = $token
$config["brain"] = "dsh"
$config["env"]   = $__env
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
Step "创建桌面快捷方式"
$Desktop = [Environment]::GetFolderPath("Desktop")

# 图标：安装器旁边有 logo.ico 就用它（全量包/离线包都带），复制进程序目录长期留着
$IconSrc = Join-Path $PSScriptRoot "logo.ico"
if (-not (Test-Path $IconSrc)) { $IconSrc = Join-Path $AppRepo "installer\logo.ico" }
$IconPath = Join-Path $AppDir "logo.ico"
if (Test-Path $IconSrc) { Copy-Item $IconSrc $IconPath -Force }

# 无黑窗启动器：VBS 静默更新 + 起服务 + 等端口 + 开浏览器
$VbsSrc = Join-Path $PSScriptRoot "launcher-template.vbs"
if (-not (Test-Path $VbsSrc)) { $VbsSrc = Join-Path $AppRepo "installer\launcher-template.vbs" }
$LauncherVbs = Join-Path $AppDir "启动.vbs"
if (Test-Path $VbsSrc) {
  $vbs = [System.IO.File]::ReadAllText($VbsSrc, [System.Text.Encoding]::UTF8)
  $vbs = $vbs.Replace("__APPDIR__", $AppDir)
  # 必须 UTF-16 带 BOM。实测 wscript 读 .vbs 的规则：
  #   UTF-8 无 BOM -> 按系统 ANSI 解，中文提示全成「鎵句笉鍒?」
  #   UTF-8 带 BOM -> 直接语法错误，脚本压根跑不起来
  #   UTF-16 带 BOM -> 正确，且跟系统语言无关（ANSI 只在中文系统上碰巧对）
  [System.IO.File]::WriteAllText($LauncherVbs, $vbs, (New-Object System.Text.UnicodeEncoding($false, $true)))

  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Desktop "群星阅览室.lnk"))
  $sc.TargetPath = "wscript.exe"
  $sc.Arguments = '"' + $LauncherVbs + '"'
  $sc.WorkingDirectory = $AppDir
  $sc.Description = "群星阅览室 — 在自己电脑上啃外文书"
  if (Test-Path $IconPath) { $sc.IconLocation = $IconPath }
  $sc.Save()
  # 老版本留下的 .bat 启动器清掉，免得桌面上两个图标
  Remove-Item (Join-Path $Desktop "启动群星阅览室.bat") -Force -ErrorAction SilentlyContinue
  Ok "桌面上有「群星阅览室」了"
} else {
  # 兜底：没有模板就退回 .bat（老路径，保证一定能启动）
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
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "  程序在: $AppDir" -ForegroundColor Green
Write-Host "  书库在: $Vault" -ForegroundColor Green
Write-Host "  双击桌面「启动群星阅览室」开始用。" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
if (-not ($InstallDir -and $ApiKey)) { Read-Host "按回车关闭本窗口" }
