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
# 配置文件固定在 ~\.shufang（几 KB，程序按这个位置找配置）；大东西装哪由用户选
$ConfigDir  = Join-Path $env:USERPROFILE ".shufang"
$ConfigPath = Join-Path $ConfigDir "config.json"

# 升级时沿用老配置。重装不该让人重填一遍 key，更不该换掉 token——
# token 一变，手机上存的那个带 ?t= 的链接就全打不开了。
$OldCfg = $null
if (Test-Path $ConfigPath) {
  try {
    $__raw  = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
    $OldCfg = ($__raw.TrimStart([char]0xFEFF)) | ConvertFrom-Json
  } catch { $OldCfg = $null }
}
$OldKey = ""
if ($OldCfg -and $OldCfg.env -and $OldCfg.env.DEEPSEEK_API_KEY) {
  $__k = [string]$OldCfg.env.DEEPSEEK_API_KEY
  # enc:v1: 是本机加密过的，原样搬过去照样能解
  if ($__k -match "^(sk-|enc:v1:)") { $OldKey = $__k }
}
$OldVault = ""
if ($OldCfg -and $OldCfg.vaultPath -and (Test-Path $OldCfg.vaultPath)) { $OldVault = [string]$OldCfg.vaultPath }

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

# ---------------------------------------------------------------- 位置选择
$DefaultApp = Join-Path $env:USERPROFILE ".shufang"
Write-Host ""
Write-Host "程序装到哪？（程序 + 运行环境，约 400MB）"
Write-Host "直接回车用默认: $DefaultApp"
Write-Host "C 盘不够就输入别的地方，比如 D:\群星阅览室"
$AppDir = ("" + (Read-Host "安装位置")).Trim().Trim('"')
if (-not $AppDir) { $AppDir = $DefaultApp }
$AppRepo = Join-Path $AppDir "app"
$NodeDir = Join-Path $AppDir "node"
$BinDir  = Join-Path $AppDir "bin"

# 老书库在哪就还用哪，别让人一路回车就把书悄悄挪回 Documents
$DefaultVault = if ($OldVault) { $OldVault } else { Join-Path ([Environment]::GetFolderPath("MyDocuments")) "书房" }
Write-Host ""
Write-Host "书库放到哪？（你的书、译文、笔记，会越来越大）"
Write-Host "直接回车用默认: $DefaultVault"
$Vault = ("" + (Read-Host "书库位置")).Trim().Trim('"')
if (-not $Vault) { $Vault = $DefaultVault }

New-Item -ItemType Directory -Force $AppDir, $BinDir, $ConfigDir | Out-Null

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
  RemoveWithRetry $NodeDir
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

# ---------------------------------------------------------------- dsh（DeepSeek Harness）
Step "安装 dsh（翻译助手的大脑，DeepSeek 官方）"
if (-not (Test-Path (Join-Path $NodeDir "dsh.cmd"))) {
  & (Join-Path $NodeDir "npm.cmd") install -g "@deepseek-ai/dsh" --silent
  if ($LASTEXITCODE -ne 0) { throw "dsh 安装失败" }
}
Ok "dsh 就绪"

# ---------------------------------------------------------------- 群星阅览室程序
Step "获取群星阅览室程序"
# 用 zip 而不是 tar.gz：仓库里有中文文件名，Windows 自带的 tar.exe 解 tar.gz 会
# 「Invalid empty pathname」炸掉；Expand-Archive（.NET）认 zip 的 UTF-8 文件名，稳。
Fetch "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/master" "$env:TEMP\sf-app.zip"
if (Test-Path "$env:TEMP\sf-app") { Remove-Item -Recurse -Force "$env:TEMP\sf-app" }
Expand-Archive -Path "$env:TEMP\sf-app.zip" -DestinationPath "$env:TEMP\sf-app" -Force
$appInner = Get-ChildItem "$env:TEMP\sf-app" -Directory | Select-Object -First 1
RemoveWithRetry $AppRepo
Move-Item $appInner.FullName $AppRepo
$sha = ((curl.exe -fsSL -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$Owner/$Repo/commits/master") -join "").Trim()
if ($sha -match '^[0-9a-f]{40}$') { Set-Content -Path (Join-Path $AppDir ".app-sha") -Value $sha -NoNewline }
Remove-Item -Recurse -Force "$env:TEMP\sf-app.zip", "$env:TEMP\sf-app" -ErrorAction SilentlyContinue
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
$wantObs = "" + (Read-Host "   要顺便装 Obsidian 吗 (y/N)")
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
# 这一段全程关掉日志记录：key 绝不能落进 shufang-install.log，
# 因为出错时我们会让用户把那个日志发给帮他装的人。
try { Stop-Transcript | Out-Null } catch {}

Step "配置 DeepSeek"
$key = $OldKey
if ($key) {
  Ok "沿用你上次填的 key（想换成别的：删掉 $ConfigPath 再装一遍）"
} else {
  Write-Host "   需要一个 DeepSeek API key（在 platform.deepseek.com 注册后创建，sk- 开头）。"
  Write-Host "   粘贴时屏幕上不会显示，这是正常的——粘完直接回车。" -ForegroundColor DarkGray
}
while (-not ($key -match "^(sk-|enc:v1:)")) {
  $sec  = Read-Host "   粘贴你的 DeepSeek API key" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try   { $key = ([Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)).Trim() }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  if (-not ($key -match "^sk-")) { Write-Host "   看起来不太对，应该是 sk- 开头的一串。再试一次。" -ForegroundColor Yellow }
}

# 本地服务器的访问令牌，用加密随机数（局域网里手机也拿它进来，别用弱随机）
# 老 token 接着用，没有才新生成
$token = ""
if ($OldCfg -and $OldCfg.token) { $token = [string]$OldCfg.token }
if (-not $token) {
  $tokenBytes = New-Object byte[] 16
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($tokenBytes) } finally { $rng.Dispose() }
  $token = -join ($tokenBytes | ForEach-Object { $_.ToString("x2") })
}

# 在老配置上改，不是推倒重来——remoteAccess、自定义端口这些都留着
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
if (-not (Test-Path $IconSrc)) { $IconSrc = Join-Path $AppRepo "installer\\logo.ico" }
$IconPath = Join-Path $AppDir "logo.ico"
if (Test-Path $IconSrc) { Copy-Item $IconSrc $IconPath -Force }

# 无黑窗启动器：VBS 静默更新 + 起服务 + 等端口 + 开浏览器
$VbsSrc = Join-Path $PSScriptRoot "launcher-template.vbs"
if (-not (Test-Path $VbsSrc)) { $VbsSrc = Join-Path $AppRepo "installer\\launcher-template.vbs" }
$LauncherVbs = Join-Path $AppDir "启动.vbs"
if (Test-Path $VbsSrc) {
  $vbs = [System.IO.File]::ReadAllText($VbsSrc, [System.Text.Encoding]::UTF8)
  $vbs = $vbs.Replace("__APPDIR__", $AppDir)
  # 必须 UTF-16 带 BOM。实测 wscript 读 .vbs 的规则：
  #   UTF-8 无 BOM  -> 按系统 ANSI 解，中文提示全成「鎵句笉鍒?」
  #   UTF-8 带 BOM  -> 直接语法错误，脚本压根跑不起来
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
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "  双击桌面「启动群星阅览室」开始用。" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch {}
Read-Host "按回车关闭本窗口"
