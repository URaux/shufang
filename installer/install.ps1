# 群星阅览室 一键安装器（零依赖版）
# 不用 winget、不用 git、不要管理员权限。所有东西装进用户目录 ~\.shufang。
# 既可编译成 exe 双击运行，也可 powershell -File 运行。

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { chcp 65001 > $null } catch {}
$LogPath = Join-Path $env:TEMP "shufang-install.log"
try { Start-Transcript -Path $LogPath -Force | Out-Null } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# 任何未捕获错误：显示人话、停住窗口，绝不闪退
trap {
  Write-Host ""
  Write-Host "[X] 安装中途出错了: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "    多半是某个下载没完成——网络不好的话挂个梯子、或换个时间重试。" -ForegroundColor Yellow
  Write-Host "    日志在 $LogPath，可以把它发给帮你装的人。" -ForegroundColor Yellow
  try { Stop-Transcript | Out-Null } catch {}
  Read-Host "按回车关闭"
  exit 1
}

$Owner  = "URaux"; $Repo = "shufang"
$AppDir  = Join-Path $env:USERPROFILE ".shufang"
$AppRepo = Join-Path $AppDir "app"
$NodeDir = Join-Path $AppDir "node"
$BinDir  = Join-Path $AppDir "bin"
$Vault   = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "书房"
$ConfigPath = Join-Path $AppDir "config.json"

New-Item -ItemType Directory -Force $AppDir, $BinDir | Out-Null

function Step($m) { Write-Host ""; Write-Host ">> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   OK: $m" -ForegroundColor Green }

function Fetch($url, $out) {
  curl.exe -fL --retry 2 --connect-timeout 25 -o "$out" "$url" 2>$null
  if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) { return }
  throw "下载失败: $url`n    网络不通或对方限速。挂个梯子、或换个时间重跑本安装器。"
}

function Expand($archive, $dest) {
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  New-Item -ItemType Directory -Force $dest | Out-Null
  $isTar = $archive -match "\.(tgz|tar\.gz)$"
  $hasTar = [bool](Get-Command tar.exe -ErrorAction SilentlyContinue)
  # tar.exe（Win10 1803+ 自带）比 Expand-Archive 快很多，且 Expand-Archive 根本不认 tar.gz
  if ($hasTar) {
    tar.exe -xf "$archive" -C "$dest"
    if ($LASTEXITCODE -ne 0) {
      if ($isTar) { throw "解压失败: $archive" }
      Expand-Archive -Path $archive -DestinationPath $dest -Force
    }
  } elseif ($isTar) {
    throw "这台电脑没有 tar.exe（Win10 1803 以前的版本才会这样）。请升级 Windows 后重试。"
  } else {
    Expand-Archive -Path $archive -DestinationPath $dest -Force
  }
}

Write-Host "=============================================="
Write-Host "  群星阅览室 · 本地啃书翻译器 安装程序"
Write-Host "  零依赖：不用管理员、不改系统、都装你自己目录里"
Write-Host "=============================================="

# ---------------------------------------------------------------- Node
Step "安装 Node（网页程序的运行环境）"
if (-not (Test-Path (Join-Path $NodeDir "node.exe"))) {
  # 阿里云 npmmirror 在国内很快且没被墙；失败回退官方
  $verJson = curl.exe -fsSL --connect-timeout 25 "https://registry.npmmirror.com/-/binary/node/latest-v22.x/" 2>$null
  $file = ([regex]::Matches($verJson, 'node-v[0-9.]+-win-x64\.zip') | Select-Object -First 1).Value
  if (-not $file) {
    $idx = curl.exe -fsSL "https://nodejs.org/dist/index.json" 2>$null | ConvertFrom-Json
    $v = ($idx | Where-Object { $_.lts } | Select-Object -First 1).version
    $file = "node-$v-win-x64.zip"
    Fetch "https://nodejs.org/dist/$v/$file" "$env:TEMP\sf-node.zip"
  } else {
    Fetch "https://registry.npmmirror.com/-/binary/node/latest-v22.x/$file" "$env:TEMP\sf-node.zip"
  }
  Expand "$env:TEMP\sf-node.zip" "$env:TEMP\sf-node"
  $inner = Get-ChildItem "$env:TEMP\sf-node" -Directory | Select-Object -First 1
  if (Test-Path $NodeDir) { Remove-Item -Recurse -Force $NodeDir }
  Move-Item $inner.FullName $NodeDir
  Remove-Item -Recurse -Force "$env:TEMP\sf-node.zip", "$env:TEMP\sf-node" -ErrorAction SilentlyContinue
}
$env:Path = "$NodeDir;$BinDir;$env:Path"
# npm 全局装到便携 node 目录（无需管理员）
& (Join-Path $NodeDir "npm.cmd") config set prefix "$NodeDir" 2>$null | Out-Null
Ok "Node $(& (Join-Path $NodeDir 'node.exe') --version) 就绪"

# ---------------------------------------------------------------- Pandoc
Step "安装 Pandoc（电子书格式转换）"
if (-not (Test-Path (Join-Path $BinDir "pandoc.exe"))) {
  $rel = curl.exe -fsSL --connect-timeout 25 "https://api.github.com/repos/jgm/pandoc/releases/latest" 2>$null | ConvertFrom-Json
  $asset = $rel.assets | Where-Object { $_.name -match "windows-x86_64\.zip$" } | Select-Object -First 1
  Fetch $asset.browser_download_url "$env:TEMP\sf-pandoc.zip"
  Expand "$env:TEMP\sf-pandoc.zip" "$env:TEMP\sf-pandoc"
  $pdoc = Get-ChildItem "$env:TEMP\sf-pandoc" -Recurse -Filter "pandoc.exe" | Select-Object -First 1
  Copy-Item $pdoc.FullName (Join-Path $BinDir "pandoc.exe") -Force
  Remove-Item -Recurse -Force "$env:TEMP\sf-pandoc.zip", "$env:TEMP\sf-pandoc" -ErrorAction SilentlyContinue
}
Ok "Pandoc 就绪"

# ---------------------------------------------------------------- Claude Code
Step "安装 Claude Code（翻译助手的大脑）"
if (-not (Test-Path (Join-Path $NodeDir "claude.cmd"))) {
  & (Join-Path $NodeDir "npm.cmd") install -g @anthropic-ai/claude-code --silent
  if ($LASTEXITCODE -ne 0) { throw "Claude Code 安装失败" }
}
Ok "Claude Code 就绪"

# ---------------------------------------------------------------- 群星阅览室程序
Step "获取群星阅览室程序"
Fetch "https://codeload.github.com/$Owner/$Repo/tar.gz/refs/heads/master" "$env:TEMP\sf-app.tgz"
Expand "$env:TEMP\sf-app.tgz" "$env:TEMP\sf-app"
$appInner = Get-ChildItem "$env:TEMP\sf-app" -Directory | Select-Object -First 1
if (Test-Path $AppRepo) { Remove-Item -Recurse -Force $AppRepo }
Move-Item $appInner.FullName $AppRepo
$sha = (curl.exe -fsSL "https://api.github.com/repos/$Owner/$Repo/commits/master" 2>$null | ConvertFrom-Json).sha
if ($sha) { Set-Content -Path (Join-Path $AppDir ".app-sha") -Value $sha -NoNewline }
Remove-Item -Recurse -Force "$env:TEMP\sf-app.tgz", "$env:TEMP\sf-app" -ErrorAction SilentlyContinue
Ok "已获取最新版"

Step "安装网页程序依赖"
Push-Location (Join-Path $AppRepo "webapp")
& (Join-Path $NodeDir "npm.cmd") install --omit=dev --silent
Pop-Location
Ok "网页程序就绪"

# ---------------------------------------------------------------- 书库
if (Test-Path $Vault) {
  Ok "书库已存在（$Vault），保留原样"
} else {
  Copy-Item -Recurse (Join-Path $AppRepo "vault-template") $Vault
  Ok "书库建在 $Vault"
}

# ---------------------------------------------------------------- 可选：Obsidian
$ObsidianInstalled = Test-Path (Join-Path $env:LOCALAPPDATA "Obsidian\Obsidian.exe")

Write-Host ""
Write-Host ">> 可选组件" -ForegroundColor Cyan
Write-Host "   群星阅览室自带网页界面，看书+对话已经够用。"
Write-Host "   Obsidian 是给想把书库当笔记库深度整理的人用的（约 100MB，可跳过）。"
$wantObs = Read-Host "   要顺便装 Obsidian 吗 (y/N)"
if ($wantObs -match "^[Yy]") {
  Step "安装 Obsidian"
  $orel = curl.exe -fsSL "https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest" 2>$null | ConvertFrom-Json
  $oasset = $orel.assets | Where-Object { $_.name -match "^Obsidian.*\.exe$" -and $_.name -notmatch "arm64" } | Select-Object -First 1
  if ($oasset) {
    Fetch $oasset.browser_download_url "$env:TEMP\sf-obsidian.exe"
    # NSIS 静默、按用户安装到 AppData，不要管理员
    Start-Process "$env:TEMP\sf-obsidian.exe" -ArgumentList "/S" -Wait
    Remove-Item -Force "$env:TEMP\sf-obsidian.exe" -ErrorAction SilentlyContinue
    $ObsidianInstalled = $true
    Ok "Obsidian 装好了"
  } else {
    Write-Host "   没取到 Obsidian 下载地址，跳过（不影响使用网页界面）。" -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------- 可选：PDF
$wantPdf = Read-Host "   要支持 PDF 格式的书吗 (y/N)"
if ($wantPdf -match "^[Yy]") {
  Step "安装 PDF 支持"
  if (Get-Command python -ErrorAction SilentlyContinue) {
    python -m pip install --quiet --user pymupdf4llm 2>$null
    Ok "PDF 支持就绪"
  } else {
    Write-Host "   没找到 Python，PDF 支持先跳过。装了 Python 后重跑本安装器即可。" -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------- API key
# 这一段全程关掉日志记录：key 绝不能落进 shufang-install.log，
# 因为出错时我们会让用户把那个日志发给帮他装的人。
try { Stop-Transcript | Out-Null } catch {}

Step "配置 DeepSeek"
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

# 本地服务器的访问令牌，用加密随机数（局域网里手机也拿它进来，别用弱随机）
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
# 必须写成不带 BOM 的 UTF-8：server.js 用 JSON.parse 读它，BOM 会让解析直接抛异常，
# 而那个异常是被 catch 吞掉当「首次运行」处理的——表现就是 key 和书库路径神秘丢失。
# （PowerShell 5.1 的 Out-File -Encoding utf8 正是带 BOM 的，不能用。）
[System.IO.File]::WriteAllText(
  $ConfigPath,
  ($config | ConvertTo-Json -Depth 4),
  (New-Object System.Text.UTF8Encoding($false))
)
$key = $null
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch {}
Ok "配置写好了"

# ---------------------------------------------------------------- 自动更新器
# 放在 app 目录外面：它要整个替换 app\，自己不能待在里面（Windows 不让删当前目录）。
Step "安装自动更新器"
$UpdaterPath = Join-Path $AppDir "update.ps1"
$updaterText = @"
# 群星阅览室自动更新器 —— 每次启动时比对 GitHub 上 master 的 commit sha，变了就整份换掉 app\。
# 由安装器生成，不随仓库更新。失败一律静默放行，绝不能挡住用户启动。
`$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
`$AppDir  = "$AppDir"
`$AppRepo = "$AppRepo"
`$ShaFile = Join-Path `$AppDir ".app-sha"
try {
  `$latest = (curl.exe -fsSL --max-time 10 "https://api.github.com/repos/$Owner/$Repo/commits/master" 2>`$null | ConvertFrom-Json).sha
  if (-not `$latest) { return }
  `$current = ""
  if (Test-Path `$ShaFile) { `$current = (Get-Content `$ShaFile -Raw).Trim() }
  if (`$latest -eq `$current) { Write-Host "已是最新版" -ForegroundColor DarkGray; return }

  Write-Host "发现新版本，更新中..." -ForegroundColor Cyan
  `$tgz = Join-Path `$env:TEMP "sf-up.tgz"
  `$tmp = Join-Path `$env:TEMP "sf-up"
  curl.exe -fL --max-time 120 -o "`$tgz" "https://codeload.github.com/$Owner/$Repo/tar.gz/refs/heads/master" 2>`$null
  if (`$LASTEXITCODE -ne 0) { return }
  if (Test-Path `$tmp) { Remove-Item -Recurse -Force `$tmp }
  New-Item -ItemType Directory -Force `$tmp | Out-Null
  tar.exe -xf "`$tgz" -C "`$tmp"
  if (`$LASTEXITCODE -ne 0) { return }
  `$inner = Get-ChildItem `$tmp -Directory | Select-Object -First 1
  if (-not `$inner) { return }

  # 先搬到旁边再删旧的，中途失败还能回滚
  `$backup = Join-Path `$AppDir "app.old"
  if (Test-Path `$backup) { Remove-Item -Recurse -Force `$backup }
  if (Test-Path `$AppRepo) { Move-Item `$AppRepo `$backup }
  try {
    Move-Item `$inner.FullName `$AppRepo
    # node_modules 不在仓库里，从旧版搬过来，省一次 npm install
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
  Remove-Item -Recurse -Force `$tgz, `$tmp -ErrorAction SilentlyContinue
} catch {
  Write-Host "检查更新时出了点问题，跳过，直接启动。" -ForegroundColor DarkGray
}
"@
[System.IO.File]::WriteAllText($UpdaterPath, $updaterText, (New-Object System.Text.UTF8Encoding($true)))
Ok "自动更新器就绪"

# ---------------------------------------------------------------- 启动器
Step "创建桌面启动器"
$Desktop = [Environment]::GetFolderPath("Desktop")
$launcher = Join-Path $Desktop "启动群星阅览室.bat"
$obsLine = if ($ObsidianInstalled) {
  'start "" "obsidian://open?path=' + [uri]::EscapeDataString($Vault) + '"'
} else {
  'rem 没装 Obsidian，跳过（网页界面已经够用）'
}
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
$obsLine
start "" http://localhost:7787/
node server.js
pause
"@
[System.IO.File]::WriteAllText($launcher, $launcherText, (New-Object System.Text.UTF8Encoding($false)))
Ok "桌面上有「启动群星阅览室」了"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "  双击桌面「启动群星阅览室」开始用。" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
Read-Host "按回车关闭本窗口"
