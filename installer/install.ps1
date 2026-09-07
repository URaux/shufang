# 群星回廊 一键安装器（零依赖版）
# 不用 winget、不用 git、不要管理员权限。所有东西装进用户目录 ~\.shufang。
# 既可编译成 exe 双击运行，也可 powershell -File 运行。
#
# 两类用户都要照顾，但用不同的办法：
#
# 傻瓜路线（默认）：什么都自带，一路回车，跟你电脑上别的东西互不干扰。
#   安装器不读你的 PATH、不改 ~/.npmrc、不动注册表（只读一下 obsidian:// 认它装没装）。
#
# 程序员路线（装完再开）：不想让它多占几百兆、想用自己那套 pandoc/dsh，
#   在 ~/.shufang/config.json 里加一行 "preferSystemTools": true 就行——
#   启动时会把你的 PATH 排在我们自带的前面，谁在前面就用谁。
#   唯独 Node 不参与：dsh 硬要 22.15+，而用 nvm 的人一句 `nvm use 18` 就能把它换掉，
#   换掉之后的表现是「聊天没反应、别的全正常」，最难查。自带一份省这份心。
#
# 之所以不在安装器里做「检测到就问你要不要复用」：那要把 Node 目录、npm 全局前缀、
# 启动器 PATH 十来处全部改成可变的，主安装路径上的风险跟收益不成比例。
# 配置文件里一行开关，效果一样，而且随时能改回来。

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { chcp 65001 > $null } catch {}
# 配置文件固定在 ~\.shufang（几 KB，程序按这个位置找配置）；大东西装哪由用户选
$ConfigDir  = Join-Path $env:USERPROFILE ".shufang"
$ConfigPath = Join-Path $ConfigDir "config.json"
# 日志也放 ~\.shufang，不放 %TEMP%：目标用户不知道 %TEMP% 是什么，资源管理器默认还藏着
# AppData，「把日志发给帮你装的人」这句话对他们等于没说。固定在这儿，桌面的
# 「复制群星回廊日志」和程序里的「复制诊断日志」都从同一个地方读。
# 追加而不是覆盖：装失败重跑是常态，上一次是怎么失败的经常正是线索。
$LogPath = Join-Path $ConfigDir "install.log"
New-Item -ItemType Directory -Force $ConfigDir | Out-Null
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch {}
Write-Host "---- 安装开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ----" -ForegroundColor DarkGray
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# 出错时把日志末尾放进剪贴板。用户不会找文件、不会截整个窗口，但「粘贴」是会的——
# 这是失败信息能到站长手里的唯一可靠通道。只取最后 200 行：重跑多次之后日志很长，
# 全量粘进聊天窗口会卡。必须定义在 trap 前面：trap 里调它，而函数要执行到定义那行才存在。
function CopyLogToClipboard() {
  try { Stop-Transcript | Out-Null } catch {}     # 先停，不然末尾几行还在缓冲区里
  try {
    $tail = Get-Content $LogPath -Tail 200 -Encoding UTF8 -ErrorAction Stop
    Set-Clipboard -Value ($tail -join [Environment]::NewLine)
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "  出错了。错误信息已经复制到剪贴板，直接粘贴给站长就行。" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Yellow
  } catch {
    Write-Host ""
    Write-Host "  出错了。日志在 $LogPath，把这个文件发给站长。" -ForegroundColor Yellow
  }
}

# 任何未捕获错误：显示人话、停住窗口，绝不闪退
trap {
  Write-Host ""
  Write-Host "[X] 安装中途出错了: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "    多半是某个下载没完成——网络不好的话挂个梯子、或换个时间重试。" -ForegroundColor Yellow
  CopyLogToClipboard
  Read-Host "按回车关闭"
  exit 1
}

$Owner  = "URaux"; $Repo = "shufang"

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
    # 路径对用户没用（他既不认识也帮不上忙），要紧的是「关窗口再来一次」
    throw "有文件正被别的程序占着，装不进去。把所有群星回廊的窗口都关掉（或者直接重启一次电脑），然后重新运行这个安装器。"
  }
}


function Fetch($url, $out) {
  curl.exe -fL --retry 2 --connect-timeout 25 -o "$out" "$url" 2>$null
  if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) { return }
  # GitHub 的下载在国内时好时坏：2026-09-05 实测直连 600KB/s，但同一天另一个时段就可能 RST。
  # 官方失败再走 gh-proxy.com 反代（原始地址整个跟在后面，实测 800KB/s）。
  # 只对 github.com 的地址这么做——别的站没有这种反代，拼上去也是白拼。
  if ($url -match "^https://(github\.com|objects\.githubusercontent\.com)/") {
    Remove-Item -Force $out -ErrorAction SilentlyContinue
    curl.exe -fL --retry 2 --connect-timeout 25 -o "$out" "https://gh-proxy.com/$url" 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $out) -and (Get-Item $out).Length -gt 0) { return }
  }
  # 人话在前，地址跟在后面单起一行——那一行是给站长看的（日志和剪贴板都会带上它），
  # 用户不用管
  throw "有个组件没下下来。多半是网络不通或者对方限速：挂个梯子，或者换个时间重新运行这个安装器。`n    （这行给站长看：$url）"
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
      if ($isTar) { throw "下下来的文件打不开，多半是没下完。重新运行一次这个安装器（会重新下）。" }
      Expand-Archive -Path $archive -DestinationPath $dest -Force
    }
  } elseif ($isTar) {
    throw "这台电脑的 Windows 太老了（Win10 1803 以前），缺一个解压要用的系统组件。把 Windows 升级一下，再重新运行这个安装器。"
  } else {
    Expand-Archive -Path $archive -DestinationPath $dest -Force
  }
}

Write-Host "=============================================="
Write-Host "  群星回廊 · 本地啃书翻译器 安装程序"
Write-Host "  零依赖：不用管理员、不改系统、都装你自己目录里"
Write-Host "=============================================="

$NEED_APP_MB = 900     # 装完约 400MB，但下载+解压中途峰值接近两倍
$NEED_VAULT_MB = 200   # 书库起步很小，但一本扫描书就能到几百 MB

# 装之前先把空间说清楚。位置选择本来就有，但只写「C 盘不够就换个地方」是不够的——
# 用户不知道要多少、也不知道自己剩多少，一路回车就把系统盘撑爆了，
# 而且炸的时候是在复制到一半，目录已经建了一堆。
function DriveFreeMB($path) {
  try {
    $root = [System.IO.Path]::GetPathRoot(([System.IO.Path]::GetFullPath($path)))
    $d = Get-PSDrive -Name $root.TrimEnd(":\") -ErrorAction Stop
    return [int]($d.Free / 1MB)
  } catch { return -1 }   # 网络盘、映射盘之类问不出来，那就别拦着
}

function ShowDrives($needMB) {
  Write-Host "   各个盘还剩多少（这次要 $([int]($needMB/1024)) GB 左右）：" -ForegroundColor DarkGray
  foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    if ($null -eq $d.Free -or $null -eq $d.Used) { continue }
    $free = [int]($d.Free / 1MB)
    $mark = if ($free -lt $needMB) { "  装不下" } else { "" }
    $color = if ($free -lt $needMB) { "DarkGray" } else { "Green" }
    Write-Host ("     {0}:  剩 {1} GB{2}" -f $d.Name, [math]::Round($d.Free / 1GB, 1), $mark) -ForegroundColor $color
  }
}

# 系统盘装不下就换个推荐：挑剩得最多、又确实够的那个盘
function PickDefaultDir($preferred, $needMB, $leafName) {
  if ((DriveFreeMB $preferred) -ge $needMB) { return $preferred }
  $best = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
    Where-Object { $_.Free -and ($_.Free / 1MB) -ge $needMB } |
    Sort-Object Free -Descending | Select-Object -First 1
  if ($best) { return (Join-Path ($best.Name + ":\") $leafName) }
  return $preferred      # 哪个盘都不够，照原样问，下面的复核会拦住
}

# 选完真核一遍。不够就当场说明白，别等复制到一半才炸。
function EnsureSpace($path, $needMB, $what) {
  $free = DriveFreeMB $path
  if ($free -lt 0) { return }                    # 问不出来就不拦
  if ($free -ge $needMB) { return }
  $root = [System.IO.Path]::GetPathRoot(([System.IO.Path]::GetFullPath($path)))
  throw ("$root 只剩 $([math]::Round($free/1024,1)) GB，装不下$what（要 $([math]::Round($needMB/1024,1)) GB）。" +
         "`n    换个空间大的盘重跑一次就行，比如 D:\群星回廊。")
}

# ---------------------------------------------------------------- 位置选择
$DefaultApp = Join-Path $env:USERPROFILE ".shufang"
Write-Host ""
$DefaultApp = PickDefaultDir $DefaultApp $NEED_APP_MB "群星回廊"
Write-Host "程序装到哪？（程序 + 运行环境，约 400MB；下载解压时峰值更高些）"
ShowDrives $NEED_APP_MB
Write-Host "直接回车用默认: $DefaultApp"
$AppDir = ("" + (Read-Host "安装位置")).Trim().Trim('"')
if (-not $AppDir) { $AppDir = $DefaultApp }
$AppRepo = Join-Path $AppDir "app"
$NodeDir = Join-Path $AppDir "node"
$BinDir  = Join-Path $AppDir "bin"

# 老书库在哪就还用哪，别让人一路回车就把书悄悄挪回 Documents
$DefaultVault = if ($OldVault) { $OldVault } else { Join-Path ([Environment]::GetFolderPath("MyDocuments")) "书房" }
Write-Host ""
Write-Host "书库放到哪？（你的书、译文、笔记，会越来越大）"
ShowDrives $NEED_VAULT_MB
Write-Host "直接回车用默认: $DefaultVault"
$Vault = ("" + (Read-Host "书库位置")).Trim().Trim('"')
if (-not $Vault) { $Vault = $DefaultVault }

EnsureSpace $AppDir $NEED_APP_MB "程序"
EnsureSpace $Vault $NEED_VAULT_MB "书库"
New-Item -ItemType Directory -Force $AppDir, $BinDir, $ConfigDir | Out-Null

# ---------------------------------------------------------------- 先停掉在跑的实例
# 程序开着的时候装/重装，node.exe 正被占用，复制会「访问被拒绝」。
# 小白不知道要先关窗口，这里自动停一下。
Step "检查有没有正在运行的群星回廊"
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
# dsh 的会话存储 import 了 zlib 的 zstd 接口，那是 Node 22.15 才有的。
# 版本低了 dsh 一启动就抛「does not provide an export named 'createZstdDecompress'」，
# 表现是聊天完全没反应（入库还好好的，因为那条路直连 API 不经过 dsh）。
$NODE_MIN = [version]"22.15.0"

# 不复用系统 Node，哪怕它版本够。
# 用 nvm / volta 的人随时会 `nvm use 18` 切走，而我们对版本的要求是硬的（22.15+），
# 切走之后的表现是「聊天一点反应没有、传书整理却完全正常」—— 用户根本联想不到
# 是自己切了 Node 版本，我们也没法远程诊断。自带一份几十兆换一个不会被外部
# 状态搞坏的运行时，划算。
#
# 反过来，我们也绝不往系统那份里装东西：dsh 一律装进我们自己的目录，
# 靠进程级的 npm_config_prefix，不碰用户的 ~/.npmrc。
Step "安装 Node（网页程序的运行环境）"
if (-not (Test-Path (Join-Path $NodeDir "node.exe"))) {

  # 阿里云 npmmirror 在国内很快且没被墙；失败回退官方。
  # 注意 latest-v22.x/ 这个目录名骗人——它列的是**所有** v22 版本，不是最新那个。
  # 原来取第一个匹配，拿到的是排在最前面的 v22.0.0（正好低于门槛，聊天全废）。
  $file = ""
  $verJson = curl.exe -fsSL --connect-timeout 25 "https://registry.npmmirror.com/-/binary/node/latest-v22.x/" 2>$null
  if ($verJson) {
    $best = [regex]::Matches($verJson, 'node-v([0-9]+\.[0-9]+\.[0-9]+)-win-x64\.zip') |
      ForEach-Object { [version]$_.Groups[1].Value } |
      Sort-Object -Descending | Select-Object -First 1
    if ($best -and $best -ge $NODE_MIN) { $file = "node-v$best-win-x64.zip" }
  }
  if ($file) {
    Fetch "https://registry.npmmirror.com/-/binary/node/latest-v22.x/$file" "$env:TEMP\sf-node.zip"
  } else {
    $idx = curl.exe -fsSL "https://nodejs.org/dist/index.json" 2>$null | ConvertFrom-Json
    $v = ($idx | Where-Object { $_.lts -and ([version]($_.version.TrimStart("v"))) -ge $NODE_MIN } |
          Select-Object -First 1).version
    if (-not $v) { throw "没找到能用的运行环境版本（要 Node 22.15 以上）。换个网络环境，再重新运行一次这个安装器。" }
    Fetch "https://nodejs.org/dist/$v/node-$v-win-x64.zip" "$env:TEMP\sf-node.zip"
  }
  Expand "$env:TEMP\sf-node.zip" "$env:TEMP\sf-node"
  $inner = Get-ChildItem "$env:TEMP\sf-node" -Directory | Select-Object -First 1
  RemoveWithRetry $NodeDir
  Move-Item $inner.FullName $NodeDir
  Remove-Item -Recurse -Force "$env:TEMP\sf-node.zip", "$env:TEMP\sf-node" -ErrorAction SilentlyContinue
}
$env:Path = "$NodeDir;$BinDir;$env:Path"
# npm 全局装到便携 node 目录（无需管理员）
# 用环境变量而不是 `npm config set prefix`。
# 后者写的是**用户全局**的 ~/.npmrc，等于把用户自己 npm i -g 的去向改掉了——
# 自己做开发的人从此往我们的目录里装包，而且卸载我们也不会还原。
# 实测残留：某台机器的 ~/.npmrc 里躺着一行指向临时打包目录的 prefix。
# 环境变量优先级本来就高于用户配置（npm config list 里标 "overridden by env"），
# 效果一样，但只影响当前这个安装进程，出了这扇门什么都没变。
$env:npm_config_prefix = $NodeDir
Ok "Node $(& (Join-Path $NodeDir 'node.exe') --version) 就绪"

# ---------------------------------------------------------------- Pandoc
Step "安装 Pandoc（电子书格式转换）"
if (-not (Test-Path (Join-Path $BinDir "pandoc.exe"))) {
  $rel = curl.exe -fsSL --connect-timeout 25 "https://api.github.com/repos/jgm/pandoc/releases/latest" 2>$null | ConvertFrom-Json
  $asset = $rel.assets | Where-Object { $_.name -match "windows-x86_64\.zip$" } | Select-Object -First 1
  if (-not $asset) { throw "问不到格式转换工具的下载地址（GitHub 那边没应答）。换个网络，或者过一会儿重新运行一次这个安装器。" }
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
  # 先走阿里云 npmmirror（国内快且稳），失败再退回官方 registry。
  # 只在这一条命令上带 --registry，不动用户的 ~/.npmrc。
  & (Join-Path $NodeDir "npm.cmd") install -g "@deepseek-ai/dsh" --silent --registry=https://registry.npmmirror.com
  if ($LASTEXITCODE -ne 0) {
    Write-Host "   镜像那边没装成，换官方源再试一次..." -ForegroundColor DarkGray
    & (Join-Path $NodeDir "npm.cmd") install -g "@deepseek-ai/dsh" --silent
  }
  if ($LASTEXITCODE -ne 0) { throw "翻译助手的大脑没装上，两个下载源都没成。检查一下网络（可能要挂梯子），然后重新运行一次这个安装器。" }
}
Ok "dsh 就绪"

# ---------------------------------------------------------------- 群星回廊程序
Step "获取群星回廊程序"
# 国内源优先。装机的人在国内，codeload 时好时坏而且没有可靠反代，这一步又是必成的
# （没有它就没有程序）。所以自己在 Cloudflare R2 上放了一份，走 download.gnosaria.com
# （国内可达），GitHub 留作兜底——R2 那份是发布时同步上去的，万一没同步成，GitHub 一定在。
$MirrorBase = "https://download.gnosaria.com/shufang"

# sha 和包必须来自同一个 commit。.app-sha 写下的是「现在装的是哪一版」，
# 写错了下次启动更新器会拿它跟远端比，比出「已是最新」，用户就永远停在旧版，
# 而且没有任何提示。所以两者同源：
#   version.json 通了 → 包也从国内源拿；
#   包没拿到（国内源半通不通）→ 回 codeload，同时把 sha 也重新从 GitHub 问一次，
#   因为两边可能差一个 commit，配错了就是上面那个「永远停在旧版」。
$sha = ""
$verRaw = ((curl.exe -fsSL --max-time 8 "$MirrorBase/version.json" 2>$null) -join "").Trim()
if ($verRaw) {
  try { $sha = "" + (($verRaw | ConvertFrom-Json).sha) } catch { $sha = "" }
}
if ($sha -notmatch '^[0-9a-f]{40}$') { $sha = "" }

# 用 zip 而不是 tar.gz：仓库里有中文文件名，Windows 自带的 tar.exe 解 tar.gz 会
# 「Invalid empty pathname」炸掉；Expand-Archive（.NET）认 zip 的 UTF-8 文件名，稳。
# 国内源那份 zip 的顶层目录也叫 shufang-master\，跟 codeload 同构，下面解压这段两个源通用。
$gotApp = $false
if ($sha) {
  curl.exe -fL --retry 2 --connect-timeout 25 -o "$env:TEMP\sf-app.zip" "$MirrorBase/shufang-master.zip" 2>$null
  if ($LASTEXITCODE -eq 0 -and (Test-Path "$env:TEMP\sf-app.zip") -and (Get-Item "$env:TEMP\sf-app.zip").Length -gt 0) { $gotApp = $true }
  if (-not $gotApp) { Write-Host "   国内源没通，改从 GitHub 拿" -ForegroundColor DarkGray; $sha = "" }
}
if (-not $gotApp) { Fetch "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/master" "$env:TEMP\sf-app.zip" }
if (-not $sha) {
  $sha = ((curl.exe -fsSL -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$Owner/$Repo/commits/master") -join "").Trim()
}
if (Test-Path "$env:TEMP\sf-app") { Remove-Item -Recurse -Force "$env:TEMP\sf-app" }
Expand-Archive -Path "$env:TEMP\sf-app.zip" -DestinationPath "$env:TEMP\sf-app" -Force
$appInner = Get-ChildItem "$env:TEMP\sf-app" -Directory | Select-Object -First 1
RemoveWithRetry $AppRepo
Move-Item $appInner.FullName $AppRepo
if ($sha -match '^[0-9a-f]{40}$') { Set-Content -Path (Join-Path $AppDir ".app-sha") -Value $sha -NoNewline }
Remove-Item -Recurse -Force "$env:TEMP\sf-app.zip", "$env:TEMP\sf-app" -ErrorAction SilentlyContinue
Ok "已获取最新版"

Step "安装网页程序依赖"
Push-Location (Join-Path $AppRepo "webapp")
& (Join-Path $NodeDir "npm.cmd") install --omit=dev --silent
# npm 失败不抛异常，只给退出码。原来没看它，装了一半也说「就绪」，
# 用户拿到的是一个双击就闪退的东西，而且日志里一个错字都没有。
$__npmRc = $LASTEXITCODE
Pop-Location
if ($__npmRc -ne 0) { throw "网页程序的组件没装齐，这样装出来是打不开的。多半是网络问题：换个时间重新运行一次这个安装器。`n    （这行给站长看：npm 退出码 $__npmRc）" }
Ok "网页程序就绪"

# ---------------------------------------------------------------- 书库
if (Test-Path $Vault) {
  Ok "书库已存在（$Vault），保留原样"
} else {
  Copy-Item -Recurse (Join-Path $AppRepo "vault-template") $Vault
  Ok "书库建在 $Vault"
}

# ---------------------------------------------------------------- Obsidian
# 译文是机器翻的，一定有要改的地方，而 Obsidian 读写的就是书库里那批 .md，
# 改完这边立刻看得到。所以它是默认装的一环，不是可选配件。
#
# 「装没装」不能靠猜路径：原来查 %LOCALAPPDATA%\Obsidian\Obsidian.exe，
# 而实测这台机器上它在 E:\Obsidian\——装到别的盘很常见，结果就是明明装了
# 却被判成没装，白下 316MB。真正该问的是 obsidian:// 这个协议有没有人接，
# 因为我们依赖的正是它。
Step "检查 Obsidian（用来自己改译文、做笔记）"
$ObsidianInstalled = $false
foreach ($root in @("HKCU:", "HKLM:")) {
  $cmd = (Get-ItemProperty "$root\SOFTWARE\Classes\obsidian\shell\open\command" -ErrorAction SilentlyContinue)."(default)"
  if ($cmd -match "obsidian") { $ObsidianInstalled = $true; break }
}

if ($ObsidianInstalled) {
  Ok "已经装过了"
} else {
  Write-Host "   要下载 316MB。网不好可以按 N 跳过，以后重跑安装器随时能补。" -ForegroundColor DarkGray
  $skipObs = "" + (Read-Host "   现在装 Obsidian 吗 (Y/n)")
  if ($skipObs -match "^[Nn]") {
    Write-Host "   跳过了。网页界面照常能看能改。" -ForegroundColor DarkGray
  } else {
    try {
      # 别用 releases/latest：2026-09 起上游把「最新」挂成了只带安卓 apk 的发布，
      # 桌面安装包在前一个发布里。翻最近几个，取第一个带 exe 的。
      $orels = curl.exe -fsSL --connect-timeout 25 "https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=8" 2>$null | ConvertFrom-Json
      $oasset = $null
      foreach ($orel in @($orels)) {
        $oasset = $orel.assets | Where-Object { $_.name -match "^Obsidian-[\d.]+\.exe$" } | Select-Object -First 1
        if ($oasset) { break }
      }
      if (-not $oasset) { throw "问不到 Obsidian 的下载地址" }
      Fetch $oasset.browser_download_url "$env:TEMP\sf-obsidian.exe"
      # NSIS 静默、按用户安装，不要管理员
      Start-Process "$env:TEMP\sf-obsidian.exe" -ArgumentList "/S" -Wait
      Remove-Item -Force "$env:TEMP\sf-obsidian.exe" -ErrorAction SilentlyContinue
      $ObsidianInstalled = $true
      Ok "Obsidian 装好了"
    } catch {
      # 装不上不该拦住整个安装 —— 群星回廊本身完全能用
      # 这里捕到的可能是 .NET 抛的英文异常，原文只写进日志（Start-Transcript 会记下）
      Write-Host "   Obsidian 这一步没装成。" -ForegroundColor Yellow
      Write-Host "   不影响使用：联网之后重新运行一次这个安装器就能补上。" -ForegroundColor Yellow
      Write-Host "   （这行给站长看：$($_.Exception.Message)）" -ForegroundColor DarkGray
    }
  }
}

# ---------------------------------------------------------------- PDF 支持
Step "检查 PDF 支持"
# 三个名字都试：运行期 ingest.js 就是 python/python3/py 轮着找的，
# 安装期口径得跟它一致，否则会出现「装的时候说没有、用的时候却有」。
# 而且不能只看 Get-Command 找不找得到 —— Windows 应用商店在 WindowsApps 下面
# 放了个同名的桩，跑起来只会弹商店。必须真问一次版本才算数。
$PyExe = ""
foreach ($cand in @("python", "python3", "py")) {
  $c = Get-Command $cand -ErrorAction SilentlyContinue
  if (-not $c) { continue }
  # 注意这里不能写 [string]$ver：PowerShell 里 [string]$null 仍然是 $null，
  # 而商店那个桩恰恰什么都不输出 —— [regex]::Match 会抛 ArgumentNullException，
  # 在 $ErrorActionPreference="Stop" 下直接把整个安装打断。只有 "" + x 一定得到字符串。
  $ver = ""
  try { $ver = "" + (& $c.Source --version 2>&1 | Select-Object -First 1) } catch { continue }
  $m = [regex]::Match($ver, "(\d+)\.(\d+)")
  if (-not $m.Success) { continue }                      # 商店那个桩答不出版本
  $major = [int]$m.Groups[1].Value; $minor = [int]$m.Groups[2].Value
  if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 9)) { continue }   # pymupdf4llm 要 3.9+
  $PyExe = $c.Source
  break
}

if ($PyExe) {
  # 版本必须钉死。pymupdf4llm 从 1.27 起 import 时就硬 import onnxruntime（自带 OCR），
  # 而 onnxruntime 在不少 Windows 机器上 DLL load failed —— 实测本机 1.22/1.28 都起不来，
  # 结果是 import 直接崩、PDF 支持静默消失，报错用户完全看不懂。0.0.27 不碰它。
  # 底座也一起钉：只钉 pymupdf4llm 的话 pymupdf 会浮动到新版，等于没钉。
  # --user：装进用户自己的包目录，不碰系统站点目录，也不需要管理员。
  & $PyExe -m pip install --quiet --user "pymupdf4llm==0.0.27" "pymupdf==1.26.3" 2>$null
  # 装完真 import 一次再说「就绪」—— 上面那个 onnxruntime 的坑正是「装上了但 import 就崩」
  & $PyExe -c "import pymupdf4llm" 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Ok "PDF 支持就绪（用你电脑上的 Python）"

    # ---- 扫描版 PDF（认字）----
    # 老书、影印本、图书馆扫的资料几乎全是「每一页都是图片」的 PDF，
    # 抽不出文字层，得先认字。单问一句而不是默默装：这一步要下将近 100 MB，
    # 家里的网慢的话会等很久，而且不读扫描件的人根本用不上。
    #
    # 用的是 rapidocr-onnxruntime（pip 装，不用另外的外部程序）。
    # **它依赖 onnxruntime，而这台项目机上实测 onnxruntime 1.22/1.28 都 DLL load failed**
    # ——上面钉死 pymupdf 版本就是为了躲开它。所以这里 fail-soft：
    # 装不上或者 import 不了，只是没有扫描件支持，正常 PDF 一点不受影响。
    $wantOcr = "" + (Read-Host "   要支持扫描版 PDF 吗？需要再下约 100 MB (y/N)")
    if ($wantOcr -match "^[Yy]") {
      Write-Host "   正在装认字组件（大约 100 MB，慢的话请耐心等）..." -ForegroundColor DarkGray
      # 版本钉死，理由跟上面 pymupdf4llm 那条一样：这东西依赖 onnxruntime，
      # 而本仓自己记着「onnxruntime 1.22/1.28 在本机 DLL load failed」。
      # 1.4.4 拉下来的是 onnxruntime 1.18.1，项目机上实测能起
      # （引擎 0.7s，一页 1.4s，中英文都认得出）。不钉的话今天装能跑、
      # 过几个月新装的人拉到坏的那版，症状跟当年一模一样。
      & $PyExe -m pip install --quiet --user "rapidocr-onnxruntime==1.4.4" 2>$null
      & $PyExe -c "import rapidocr_onnxruntime" 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Ok "扫描版 PDF 也能读了"
      } else {
        Write-Host "   认字组件跑不起来，扫描版 PDF 暂时读不了（普通 PDF 不受影响）。" -ForegroundColor Yellow
        Write-Host "   多半是缺「Microsoft Visual C++ 运行库」，装上再重跑一次本安装器试试。" -ForegroundColor Yellow
      }
    } else {
      Write-Host "   跳过了。以后想读扫描版的书，重跑一次本安装器，这一步选 y 就行。" -ForegroundColor DarkGray
    }
  } else {
    Write-Host "   PDF 组件装上了但跑不起来，PDF 格式的书暂时读不了（epub/txt/docx 不受影响）。" -ForegroundColor Yellow
  }
} else {

  Write-Host "   这台电脑没装 Python，PDF 格式的书暂时读不了（epub/txt/docx 不受影响）。" -ForegroundColor Yellow
  Write-Host "   想读 PDF：去 python.org 装一个 Python，再重跑一次本安装器就行。" -ForegroundColor Yellow
}

# 粘 API key 时带进来的脏东西比想象中多：网页上复制会捎上不断行空格、零宽字符、方向标记、BOM；
# 中文输入法开着全角会把 sk- 打成「ｓｋ－」；手动跨行选中会夹一个换行；有人连两边的引号一起复制走。
# 这些用户自己看不见——屏幕上就是一串正常的 key——所以先尽力洗干净再判，别只甩一句「格式不对」。
function Get-CleanKey([string]$s) {
  if (-not $s) { return "" }
  $s = $s -replace '[\u200B-\u200F\u2028\u2029\u2060\uFEFF]', ''
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    $c = [int][char]$ch
    if ($c -ge 0xFF01 -and $c -le 0xFF5E) { [void]$sb.Append([char]($c - 0xFEE0)) } else { [void]$sb.Append($ch) }
  }
  $s = $sb.ToString()
  $s = $s -replace '[\u2010-\u2015\u2212\u30FC]', '-'
  $s = $s -replace '\s', ''
  $s = $s -replace '^[''"\u2018\u201C\u300C\u300E\u300A]+', ''
  $s = $s -replace '[''"\u2019\u201D\u300D\u300F\u300B]+$', ''
  return $s
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
$keyTries = 0
while (-not ($key -match "^(sk-|enc:v1:)")) {
  $keyTries++
  if ($keyTries -eq 1) {
    # 第一次用隐藏输入：key 不该显示在屏幕上，也不该落进抄录下来的日志里。
    $sec  = Read-Host "   粘贴你的 DeepSeek API key" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $key = Get-CleanKey ([Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  } else {
    # 有用户反馈：往隐藏输入框里粘贴只进去一个字符，最后只能一个个手打。
    # 隐藏输入在不同终端、不同输入法下对粘贴的处理不一样，屏幕上又什么都不显示，
    # 人根本看不出粘漏了。所以第二次起换成明文输入框——粘完自己就能看见对不对。
    Write-Host "   换个能看见的输入框（key 会显示在屏幕上，装完把窗口关掉就行）。" -ForegroundColor DarkGray
    $key = Get-CleanKey ("" + (Read-Host "   粘贴你的 DeepSeek API key"))
  }
  if (-not ($key -match "^sk-")) {
    if (-not $key) {
      Write-Host "   什么都没粘进来。用鼠标右键粘贴（或 Ctrl+V），再回车。" -ForegroundColor Yellow
    } elseif ($key.Length -lt 12) {
      Write-Host "   只读到 $($key.Length) 个字符——粘贴多半没进去全。下一次会换成能看见的输入框。" -ForegroundColor Yellow
    } else {
      $head = $key.Substring(0, [Math]::Min(8, $key.Length))
      Write-Host "   这串是「$head…」开头的，不是 sk-。DeepSeek 的 key 一定 sk- 开头——是不是把 key 的名字、或者网页上别的一段复制过来了？" -ForegroundColor Yellow
    }
  }
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
# 群星回廊自动更新器 —— 每次启动时比对远端 master 的 commit sha，变了就整份换掉 app\。
# 版本号先问国内源（download.gnosaria.com），问不到再问 GitHub。
# 由安装器生成，不随仓库更新。失败一律静默放行，绝不能挡住用户启动。
`$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
`$AppDir  = "$AppDir"
`$AppRepo = "$AppRepo"
`$ShaFile = Join-Path `$AppDir ".app-sha"
try {
  # 国内源优先：GitHub 在国内时通时不通，而这一步跑在每次启动上，不能等太久。
  `$latest = ""
  `$verRaw = ((curl.exe -fsSL --max-time 8 "$MirrorBase/version.json" 2>`$null) -join "").Trim()
  if (`$verRaw) { try { `$latest = "" + ((`$verRaw | ConvertFrom-Json).sha) } catch { `$latest = "" } }
  `$fromMirror = (`$latest -match '^[0-9a-f]{40}$')
  if (-not `$fromMirror) {
    `$latest = ((curl.exe -fsSL --max-time 10 -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$Owner/$Repo/commits/master") -join "").Trim()
  }
  if (`$latest -notmatch '^[0-9a-f]{40}$') { return }
  if (-not `$latest) { return }
  `$current = ""
  if (Test-Path `$ShaFile) { `$current = (Get-Content `$ShaFile -Raw).Trim() }
  if (`$latest -eq `$current) { Write-Host "已是最新版" -ForegroundColor DarkGray; return }

  Write-Host "发现新版本，更新中..." -ForegroundColor Cyan
  `$zip = Join-Path `$env:TEMP "sf-up.zip"
  `$tmp = Join-Path `$env:TEMP "sf-up"
  # sha 和包必须是同一个 commit：下面会把 `$latest 写进 .app-sha，
  # 写了跟实际装的包对不上的 sha，下次启动就比出「已是最新」，用户永远卡在这一版。
  # 所以版本号哪来的、包就哪来的；国内源的包没拿到，才回 GitHub，
  # 而且回退时把 sha 也重新从 GitHub 问一次（两边可能差一个 commit）。
  `$got = `$false
  if (`$fromMirror) {
    curl.exe -fsSL --max-time 120 -o "`$zip" "$MirrorBase/shufang-master.zip"
    if (`$LASTEXITCODE -eq 0) { `$got = `$true } else { Write-Host "国内源没通，改从 GitHub 拿" -ForegroundColor DarkGray }
  }
  if (-not `$got) {
    if (`$fromMirror) {
      `$latest = ((curl.exe -fsSL --max-time 10 -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$Owner/$Repo/commits/master") -join "").Trim()
      if (`$latest -notmatch '^[0-9a-f]{40}$') { return }
    }
    curl.exe -fsSL --max-time 120 -o "`$zip" "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/master"
    if (`$LASTEXITCODE -ne 0) { return }
  }
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
    Write-Host "这次没更新成，先用现在这个版本，功能都在。下次启动会再试一遍。" -ForegroundColor Yellow
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

  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Desktop "群星回廊.lnk"))
  $sc.TargetPath = "wscript.exe"
  $sc.Arguments = '"' + $LauncherVbs + '"'
  $sc.WorkingDirectory = $AppDir
  $sc.Description = "群星回廊 — 在自己电脑上啃外文书"
  if (Test-Path $IconPath) { $sc.IconLocation = $IconPath }
  $sc.Save()
  # 老版本留下的 .bat 启动器清掉，免得桌面上两个图标
  Remove-Item (Join-Path $Desktop "启动群星回廊.bat") -Force -ErrorAction SilentlyContinue
  Ok "桌面上有「群星回廊」了"
} else {
  # 兜底：没有模板就退回 .bat（老路径，保证一定能启动）
  $launcher = Join-Path $Desktop "启动群星回廊.bat"
$obsLine = if ($ObsidianInstalled) {
  'start "" "obsidian://open?path=' + [uri]::EscapeDataString($Vault) + '"'
} else {
  'rem 没装 Obsidian，跳过（网页界面已经够用）'
}
$launcherText = @"
@echo off
chcp 65001 >nul
title 群星回廊
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
  Ok "桌面上有「启动群星回廊」了"
}

# 「复制群星回廊日志」：装好了但起不来的时候，用户唯一做得到的事。
# 跟启动器一样是 VBS + 快捷方式（同一套 UTF-16 编码规矩，理由见上面），
# 双击一下就把 install.log + app.log 的末尾放进剪贴板，弹一句「粘贴给站长」。
# 它不认安装位置（日志固定在 ~\.shufang），所以模板里没有占位符要换。
$CopySrc = Join-Path $PSScriptRoot "copylog-template.vbs"
if (-not (Test-Path $CopySrc)) { $CopySrc = Join-Path $AppRepo "installer\copylog-template.vbs" }
if (Test-Path $CopySrc) {
  $CopyVbs = Join-Path $AppDir "复制日志.vbs"
  $cv = [System.IO.File]::ReadAllText($CopySrc, [System.Text.Encoding]::UTF8)
  [System.IO.File]::WriteAllText($CopyVbs, $cv, (New-Object System.Text.UnicodeEncoding($false, $true)))
  $sc2 = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Desktop "复制群星回廊日志.lnk"))
  $sc2.TargetPath = "wscript.exe"
  $sc2.Arguments = '"' + $CopyVbs + '"'
  $sc2.WorkingDirectory = $AppDir
  $sc2.Description = "出问题时双击：把群星回廊的日志复制到剪贴板，粘贴给站长"
  if (Test-Path $IconPath) { $sc2.IconLocation = $IconPath }
  $sc2.Save()
  Ok "桌面上有「复制群星回廊日志」了（出问题时用）"
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  安装完成！" -ForegroundColor Green
Write-Host "  双击桌面「启动群星回廊」开始用。" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  如果之后启动出问题，双击桌面的『复制群星回廊日志』就能把日志复制到剪贴板。" -ForegroundColor Yellow
try { Stop-Transcript | Out-Null } catch {}
Read-Host "按回车关闭本窗口"
