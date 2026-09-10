# 群星回廊 全量包安装器 —— 零下载、零依赖，全部东西都在包里。
# 给卡在网络问题上的用户：解压后双击「一键安装.bat」跑到这里。
# 支持自选安装位置（C 盘满了的人装 D 盘）。
# 也可以带参数静默安装（帮别人远程装机用）：
#   powershell -File setup-bundle.ps1 -InstallDir D:\群星回廊 -VaultDir D:\书库 -ApiKey sk-xxx
param(
  [string]$InstallDir = "",
  [string]$VaultDir = "",
  [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"

# native 命令（pip / python / curl / npm 这些）的 stderr，在 PowerShell 5.1 里会被包成
# ErrorRecord；而本脚本开头是 $ErrorActionPreference = "Stop"，于是**哪怕只是一句 WARNING**
# 也会被当成终止错误，把整个安装打断。有用户就卡在 pip 那句无害的提示上：
#   WARNING: The script pymupdf.exe is installed in ...\Scripts which is not on PATH.
# 一句「装好了但那个目录不在 PATH 里」，跟我们要的功能一点关系都没有（我们是 python -c 导入，
# 不走命令行脚本），却让他整个装不上。
# 所以凡是调外部程序，都从这儿走：临时把 Stop 降成 Continue，成没成只看退出码。
function Invoke-Native {
  param([Parameter(Mandatory = $true)][string]$Exe, [string[]]$Arguments = @())
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $Exe @Arguments 2>&1 | Out-Null
    return $LASTEXITCODE
  } finally { $ErrorActionPreference = $old }
}

# 同上，但把对方说的话留下来。
#
# 为什么要有这一个：所有 native 调用都 | Out-Null 之后，一旦「装上了却 import 不了」，
# 屏幕上只有一句「跑不起来」，没有任何线索——用户问「为什么」，我们也答不上来，
# 只能猜。有用户就卡在这一步来回换 Python 换了半天。**恰恰是失败的时候最需要那几行字。**
function Invoke-NativeSay {
  param([Parameter(Mandatory = $true)][string]$Exe, [string[]]$Arguments = @())
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & $Exe @Arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = ("" + $out).Trim() }
  } finally { $ErrorActionPreference = $old }
}

# 出错时把原文摊出来（掐到前几行，别刷屏）。英文看不懂不要紧，
# 用户把这几行发给站长，站长一眼就知道是缺运行库、是网不通、还是版本不对。
function Show-Why {
  param([string]$Title, [string]$Text, [int]$Lines = 6)
  if (-not $Text) { return }
  Write-Host "   $Title" -ForegroundColor DarkGray
  foreach ($l in (($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First $Lines)) {
    Write-Host "     $l" -ForegroundColor DarkGray
  }
}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { chcp 65001 > $null } catch {}
# 配置文件固定在 ~\.shufang（几 KB，程序按这个位置找配置；大东西都在你选的地方）
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

trap {
  Write-Host ""
  Write-Host "[X] 安装中途出错了: $($_.Exception.Message)" -ForegroundColor Red
  CopyLogToClipboard
  Read-Host "按回车关闭"
  exit 1
}

$Payload = Join-Path $PSScriptRoot "payload"
if (-not (Test-Path (Join-Path $Payload "node\node.exe"))) {
  Write-Host "[X] 少了安装要用的文件，装不了。" -ForegroundColor Red
  Write-Host "    你多半是在压缩包里面直接双击的——先把整个压缩包解压出来（右键「全部解压」），再从解压出来的文件夹里运行一次。" -ForegroundColor Yellow
  Read-Host "按回车关闭"
  exit 1
}

function Step($m) { Write-Host ""; Write-Host ">> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "   OK: $m" -ForegroundColor Green }

function NormalizePath([string]$p) {
  # 中文输入法打出来的冒号是全角「：」。PowerShell 不认它作盘符分隔符，
  # 「D：\文件」就不是绝对路径了，会被当成相对路径拼到当前目录后面 ——
  # 一路装到第 180 行复制运行环境时才炸，报的还是一串没人看得懂的路径
  # （实测：未能找到路径 "...\解压目录\D：\文件\node\node_modules\..."）。
  # 所以在这里当场换回半角，把问题挡在输入的那一刻。
  if (-not $p) { return $p }
  $p = $p.Trim().Trim('"').Trim("'")
  foreach ($pair in @(@('：', ':'), @('＼', '\'), @('／', '/'), @('．', '.'), @('　', ' '))) {
    $p = $p.Replace($pair[0], $pair[1])
  }
  # 全角英文字母（盘符打成 Ｄ 的）
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $p.ToCharArray()) {
    $c = [int][char]$ch
    if (($c -ge 0xFF21 -and $c -le 0xFF3A) -or ($c -ge 0xFF41 -and $c -le 0xFF5A)) {
      [void]$sb.Append([char]($c - 0xFEE0))
    } else { [void]$sb.Append($ch) }
  }
  # 「D: \文件」这种冒号后头多打了空格的，同样不算绝对路径
  $out = ([regex]::Replace($sb.ToString(), '^([A-Za-z]):[\s]+\\', '$1:\')).Trim()

  # 「D:」和「D:书房」都要补上那一道杠。
  #
  # 这一条是用户踩出来的：有人直接填了「D:」（很自然——「放 D 盘」），
  # 而 New-Item 对「D:」报的是「路径的形式不合法」，整个安装当场断在那里。
  # 而且 IsPathRooted("D:") 是 **true**，上面那道关拦不住它。
  # 更阴的是它偶尔能「装成功」：Test-Path "D:" 为真就跳过建目录，
  # 于是 vaultPath 存成了「D:」——那是「D 盘的当前目录」，书最后落到哪儿谁也说不准。
  if ($out -match '^([A-Za-z]):$') { return ($out + '\') }
  if ($out -match '^([A-Za-z]):([^\\/].*)$') { return ($Matches[1] + ':\' + $Matches[2]) }
  return $out
}

# 盘根不是一个能装东西的地方。
#
# New-Item -ItemType Directory -Force "E:\" 抛的是「路径的形式不合法」，
# 在真实存在的盘上也一样抛 —— 所以光把「D:」补成「D:\」不够，那只是把
# 崩溃从一行挪到了另一行。
#
# 而填「D:」的人想说的从来不是「装进盘根」，是「放 D 盘」。替他补个文件夹名，
# 比弹一句「这个位置不行」再让他重填一遍强。
# 资源管理器里也选得出盘根，所以这一道跟手输那一道都得走。
function RootToFolder([string]$p, [string]$leaf) {
  if (-not $p) { return $p }
  try {
    $full = [System.IO.Path]::GetFullPath($p)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd([char]92) -eq $root.TrimEnd([char]92)) { return (Join-Path $root $leaf) }
  } catch { }
  return $p
}

function ReadPath([string]$prompt, [string]$fallback) {
  # 归一化之后还不是绝对路径就重问，不要带着一个坏路径往下走。
  for ($i = 1; $i -le 3; $i++) {
    $v = NormalizePath ("" + (Read-Host $prompt))
    if (-not $v) { return $fallback }
    if ([System.IO.Path]::IsPathRooted($v)) { return $v }
    Write-Host "   「$v」不是一个完整路径。" -ForegroundColor Yellow
    Write-Host "   最常见的原因是冒号打成了全角「：」——请切到英文输入法，写成 D:\群星回廊 这样。" -ForegroundColor Yellow
  }
  throw "位置填了三次都不是完整路径。请切到英文输入法后重新运行安装器。"
}

# ---------------------------------------------------------------- 图形界面那一步
#
# 为什么要有它：这个安装器要问的几件事里，最容易出错的是「装到哪」。
# 手打路径踩过的坑都不是笔误级别的：
#   全角冒号「D：\书房」——中文输入法下顺手就打出来了，不算绝对路径，
#   一路装到一半才炸，报的还是一串没人看得懂的路径；
#   光秃盘符「D:」——New-Item 直接报「路径的形式不合法」，安装当场断；
#   偶尔还能「装成功」，那更糟：「D:」是 D 盘的**当前目录**，书落到哪儿谁也说不准。
# 这两个坑在资源管理器里选目录时根本不存在——选出来的一定是真实存在的绝对路径。
#
# 做成一个窗口而不是接连几个对话框：三件事一屏看完，改哪一项都不用从头再来。
# 装完的过程还是照旧在黑窗口里滚日志——出了岔子那些字是唯一的线索，不能藏。
#
# 窗口起不来就退回命令行问（远程会话、精简版系统、WinForms 加载失败都可能）。
# 这条退路必须留着：图形界面是为了少出错，不该变成多一处装不上的理由。
function TryLoadForms() {
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    # 这两句必须赶在任何控件被 new 出来之前；重复调用会抛，所以各自吞掉。
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
    return $true
  } catch { return $false }
}

# 选目录。用户填的那个可能还不存在（他就是想新建一个），
# 那就沿着父目录往上找一个真实存在的当起点，别让对话框开在一个莫名其妙的地方。
function PickFolder([string]$cur, [string]$desc) {
  $start = ""
  $p = ("" + $cur).Trim()
  for ($i = 0; $i -lt 8 -and $p; $i++) {
    if (Test-Path -LiteralPath $p) { $start = $p; break }
    $parent = ""
    try { $parent = [System.IO.Path]::GetDirectoryName($p) } catch {}
    if (-not $parent -or $parent -eq $p) { break }
    $p = $parent
  }
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = $desc
  $dlg.ShowNewFolderButton = $true
  if ($start) { $dlg.SelectedPath = $start }
  $r = $dlg.ShowDialog()
  $out = ""
  if ($r -eq [System.Windows.Forms.DialogResult]::OK) { $out = $dlg.SelectedPath }
  $dlg.Dispose()
  return $out
}

function Show-SetupForm([string]$defaultApp, [string]$defaultVault, [string]$oldBrain, [bool]$hasOldKey) {
  if (-not (TryLoadForms)) { return $null }

  $F = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)
  $mkLabel = {
    param($text, $x, $y, $w, $gray)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $false
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 20)
    $l.Font = $F
    if ($gray) { $l.ForeColor = [System.Drawing.Color]::Gray }
    return $l
  }

  $form = New-Object System.Windows.Forms.Form
  $form.Text = "群星回廊 · 安装"
  $form.Font = $F
  $form.ClientSize = New-Object System.Drawing.Size(600, 470)
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false; $form.MinimizeBox = $false
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.BackColor = [System.Drawing.Color]::White

  $form.Controls.Add((& $mkLabel "选好位置就行，剩下的我来。装的过程会在黑窗口里滚字，那是正常的。" 24 18 560 $true))

  # ---- 程序装到哪 ----
  $form.Controls.Add((& $mkLabel "程序装到哪？（程序本体 + 运行环境）" 24 56 400 $false))
  $tbApp = New-Object System.Windows.Forms.TextBox
  $tbApp.Location = New-Object System.Drawing.Point(24, 80)
  $tbApp.Size = New-Object System.Drawing.Size(450, 26)
  $tbApp.Font = $F
  $tbApp.Text = $defaultApp
  $form.Controls.Add($tbApp)
  $btApp = New-Object System.Windows.Forms.Button
  $btApp.Text = "浏览…"
  $btApp.Location = New-Object System.Drawing.Point(484, 79)
  $btApp.Size = New-Object System.Drawing.Size(92, 28)
  $btApp.Font = $F
  $btApp.Add_Click({ $v = PickFolder $tbApp.Text "把群星回廊装到哪个文件夹"; if ($v) { $tbApp.Text = $v } }.GetNewClosure())
  $form.Controls.Add($btApp)

  # ---- 书库放到哪 ----
  $form.Controls.Add((& $mkLabel "书库放到哪？（你的书、译文、笔记都在这，会越来越大）" 24 120 500 $false))
  $tbVault = New-Object System.Windows.Forms.TextBox
  $tbVault.Location = New-Object System.Drawing.Point(24, 144)
  $tbVault.Size = New-Object System.Drawing.Size(450, 26)
  $tbVault.Font = $F
  $tbVault.Text = $defaultVault
  $form.Controls.Add($tbVault)
  $btVault = New-Object System.Windows.Forms.Button
  $btVault.Text = "浏览…"
  $btVault.Location = New-Object System.Drawing.Point(484, 143)
  $btVault.Size = New-Object System.Drawing.Size(92, 28)
  $btVault.Font = $F
  $btVault.Add_Click({ $v = PickFolder $tbVault.Text "书库放在哪个文件夹"; if ($v) { $tbVault.Text = $v } }.GetNewClosure())
  $form.Controls.Add($btVault)

  # ---- 谁来当大脑 ----
  $form.Controls.Add((& $mkLabel "谁来当大脑？" 24 190 300 $false))
  $rbDsh = New-Object System.Windows.Forms.RadioButton
  $rbDsh.Text = "用你们代管的（推荐）　填一个 DeepSeek key，装完就能用"
  $rbDsh.Location = New-Object System.Drawing.Point(28, 216)
  $rbDsh.Size = New-Object System.Drawing.Size(552, 24)
  $rbDsh.Font = $F
  $form.Controls.Add($rbDsh)
  $rbCodex = New-Object System.Windows.Forms.RadioButton
  $rbCodex.Text = "用我自己的 Codex 订阅　这台电脑上要先装好 Codex 并登录过"
  $rbCodex.Location = New-Object System.Drawing.Point(28, 242)
  $rbCodex.Size = New-Object System.Drawing.Size(552, 24)
  $rbCodex.Font = $F
  $form.Controls.Add($rbCodex)
  $rbCc = New-Object System.Windows.Forms.RadioButton
  $rbCc.Text = "用我自己的 Claude 订阅　这台电脑上要先装好 Claude Code 并登录过"
  $rbCc.Location = New-Object System.Drawing.Point(28, 268)
  $rbCc.Size = New-Object System.Drawing.Size(552, 24)
  $rbCc.Font = $F
  $form.Controls.Add($rbCc)
  if ($oldBrain -eq "codex") { $rbCodex.Checked = $true }
  elseif ($oldBrain -eq "cc") { $rbCc.Checked = $true }
  else { $rbDsh.Checked = $true }

  # ---- key ----
  $lbKey = & $mkLabel "DeepSeek API key（在 platform.deepseek.com 创建，sk- 开头）" 24 306 520 $false
  $form.Controls.Add($lbKey)
  $tbKey = New-Object System.Windows.Forms.TextBox
  $tbKey.Location = New-Object System.Drawing.Point(24, 330)
  $tbKey.Size = New-Object System.Drawing.Size(552, 26)
  $tbKey.Font = $F
  # 不遮住：粘贴进没进去、粘全没粘全，用户得自己看得见。
  # 这是有人反馈过的——隐藏输入框里粘贴只进去一个字符，屏幕上什么都不显示，
  # 人根本看不出粘漏了，最后只能一个字一个字手打。
  $form.Controls.Add($tbKey)
  $lbKeyHint = & $mkLabel "" 24 358 552 $true
  if ($hasOldKey) { $lbKeyHint.Text = "留空就沿用你上次填的那把。" }
  else { $lbKeyHint.Text = "这把 key 只存在你自己电脑上，会加密，谁也看不到。" }
  $form.Controls.Add($lbKeyHint)

  # 选了自己的订阅就把 key 那一格灰掉——不是藏起来：
  # 让人看见「这一步不用填了」，比让它凭空消失更让人放心。
  $syncKey = {
    $on = $rbDsh.Checked
    $lbKey.Enabled = $on; $tbKey.Enabled = $on; $lbKeyHint.Enabled = $on
  }.GetNewClosure()
  $rbDsh.Add_CheckedChanged($syncKey)
  $rbCodex.Add_CheckedChanged($syncKey)
  $rbCc.Add_CheckedChanged($syncKey)
  & $syncKey

  # ---- 出错提示 ----
  $lbErr = & $mkLabel "" 24 386 552 $false
  $lbErr.ForeColor = [System.Drawing.Color]::Firebrick
  $form.Controls.Add($lbErr)

  # ---- 按钮 ----
  $btGo = New-Object System.Windows.Forms.Button
  $btGo.Text = "开始安装"
  $btGo.Location = New-Object System.Drawing.Point(388, 418)
  $btGo.Size = New-Object System.Drawing.Size(100, 32)
  $btGo.Font = $F
  $form.Controls.Add($btGo)
  $btCancel = New-Object System.Windows.Forms.Button
  $btCancel.Text = "取消"
  $btCancel.Location = New-Object System.Drawing.Point(496, 418)
  $btCancel.Size = New-Object System.Drawing.Size(80, 32)
  $btCancel.Font = $F
  $btCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $form.Controls.Add($btCancel)
  $form.CancelButton = $btCancel

  $script:__setupResult = $null
  $btGo.Add_Click({
    $lbErr.Text = ""
    $a = NormalizePath $tbApp.Text
    $v = NormalizePath $tbVault.Text
    if (-not $a -or -not [System.IO.Path]::IsPathRooted($a)) {
      $lbErr.Text = "程序位置不是一个完整路径。点「浏览…」选一个最稳妥。"; return
    }
    if (-not $v -or -not [System.IO.Path]::IsPathRooted($v)) {
      $lbErr.Text = "书库位置不是一个完整路径。点「浏览…」选一个最稳妥。"; return
    }
    if ($a -eq $v) { $lbErr.Text = "程序和书库不能是同一个文件夹。"; return }
    $b = "dsh"
    if ($rbCodex.Checked) { $b = "codex" } elseif ($rbCc.Checked) { $b = "cc" }
    $k = ("" + $tbKey.Text).Trim()
    if ($b -eq "dsh") {
      if (-not $k -and $hasOldKey) { $k = "" }          # 空着 = 沿用上次那把
      elseif ($k -notmatch "^sk-") {
        $lbErr.Text = if ($k) { "这串不是 sk- 开头的——是不是把 key 的名字复制过来了？" }
                      else { "还没填 key。或者选下面两条，用你自己的订阅。" }
        return
      }
    } else { $k = "" }
    $script:__setupResult = @{ AppDir = $a; Vault = $v; Brain = $b; Key = $k }
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
  }.GetNewClosure())

  [void]$form.ShowDialog()
  $form.Dispose()
  return $script:__setupResult
}

function RemoveWithRetry($path) {
  # Windows 关掉进程后文件句柄要过一会儿才释放，直接删常报「正在使用中」。
  for ($i = 1; $i -le 8; $i++) {
    if (-not (Test-Path $path)) { return }
    try { Remove-Item -Recurse -Force $path -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 600 }
  }
  # 还删不掉就改名让路，下次启动前清理
  try { Rename-Item $path "$path.old-$(Get-Random)" -ErrorAction Stop } catch {
    # 同 install.ps1：路径对用户没用，要紧的是「关窗口再来一次」
    throw "有文件正被别的程序占着，装不进去。把所有群星回廊的窗口都关掉（或者直接重启一次电脑），然后重新运行这个安装器。"
  }
}


Write-Host "=============================================="
Write-Host "  群星回廊 · 全量包安装"
Write-Host "  所有东西都在包里，不用下载、不要管理员"
Write-Host "=============================================="

$NEED_APP_MB = 900      # 全量包铺开约 700MB，留点余量
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

# ---------------------------------------------------------------- 读老配置
# 升级场景：key / token / 端口 / 书库位置都沿用，别让人重填一遍。
# token 尤其重要——它变了的话，手机上存的那个带 ?t= 的链接就全失效了。
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

# ---------------------------------------------------------------- 位置选择
$DefaultVaultForGui = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "书房"
if ($OldVault) { $DefaultVaultForGui = $OldVault }

# ---------------------------------------------------------------- 先试一次图形界面
# 一个窗口把「装到哪、书库放哪、谁当大脑、key」一次问完。成了就把下面那几段
# 命令行问答全跳过；窗口起不来、或者用户按了取消，就照旧一问一答。
#
# 最要紧的是那两个「浏览…」按钮：手打路径踩出来的坑（全角冒号「D：」、光秃盘符
# 「D:」）在资源管理器里选目录时根本不会发生 —— 选出来的一定是真实存在的绝对路径。
# 这两个坑都是用户实打实踩过的，一个装到一半才炸，一个装完书不知道去哪儿了。
$GUI = $null
if (-not $InstallDir -and -not $ApiKey) {
  $__da = PickDefaultDir (Join-Path $env:USERPROFILE ".shufang") $NEED_APP_MB "群星回廊"
  $__ob = ""
  if ($OldCfg -and $OldCfg.brain) { $__ob = [string]$OldCfg.brain }
  $GUI = Show-SetupForm $__da $DefaultVaultForGui $__ob ([bool]$OldKey)
}

$DefaultApp = Join-Path $env:USERPROFILE ".shufang"
if ($InstallDir) {
  $AppDir = $InstallDir
} elseif ($GUI) {
  $AppDir = $GUI.AppDir
} else {
  $DefaultApp = PickDefaultDir $DefaultApp $NEED_APP_MB "群星回廊"
  Write-Host ""
  Write-Host "程序装到哪？（程序本体 + 运行环境，约 700MB）"
  ShowDrives $NEED_APP_MB
  Write-Host "直接回车用默认: $DefaultApp"
  $AppDir = ReadPath "安装位置" $DefaultApp
}
$AppDir = RootToFolder (NormalizePath $AppDir) "群星回廊"
if (-not [System.IO.Path]::IsPathRooted($AppDir)) {
  throw "安装位置「$AppDir」不是完整路径（冒号是不是打成了全角「：」？）。请写成 D:\群星回廊 这样。"
}
if ($AppDir -match '[\u4e00-\u9fff]') {
  # 中文路径本身没问题，但个别 npm 包对非 ASCII cwd 犯病，提示一句不拦着
  Write-Host "   （路径带中文一般没事，万一之后出怪问题可以换成纯英文路径重装）" -ForegroundColor DarkGray
}
EnsureSpace $AppDir $NEED_APP_MB "程序"
New-Item -ItemType Directory -Force $AppDir | Out-Null

$DefaultVault = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "书房"
if ($VaultDir) {
  $Vault = $VaultDir
} elseif ($GUI) {
  $Vault = $GUI.Vault
} else {
  Write-Host ""
  Write-Host "书库放到哪？（你的书、译文、笔记都在这，会越来越大）"
  ShowDrives $NEED_VAULT_MB
  Write-Host "直接回车用默认: $DefaultVault"
  $__vd = $DefaultVault
  if ($OldVault) { $__vd = $OldVault }
  $Vault = ReadPath "书库位置" $__vd
}
$Vault = RootToFolder (NormalizePath $Vault) "书房"
if (-not [System.IO.Path]::IsPathRooted($Vault)) {
  throw "书库位置「$Vault」不是完整路径（冒号是不是打成了全角「：」？）。请写成 D:\书库 这样。"
}

# 书库的空间检查得等 $Vault 真的有值了再做。
# 这一行以前在上面——那时候 $Vault 还是空的，DriveFreeMB 问不出来就返回 -1，
# 于是这道关一直是空跑的：书库选到一个装不下的盘也不会被拦下来。
EnsureSpace $Vault $NEED_VAULT_MB "书库"

$NodeDir = Join-Path $AppDir "node"
$BinDir  = Join-Path $AppDir "bin"
$AppRepo = Join-Path $AppDir "app"

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

# ---------------------------------------------------------------- 落料
Step "安放运行环境（Node + Pandoc + dsh，已内置）"
# 用 robocopy 而不是 Copy-Item：Windows 的 260 字符全路径上限。
# dsh 的依赖树里最长的相对路径两百来字符，Copy-Item 一碰到就抛「未能找到路径 ... 的一部分」，
# 而且是**拷到一半**抛——用户看到一句报错，装完却以为成了，聊天永远起不来
# （日志里是 Cannot find package @deepseek-ai/dsh-app-boot）。有用户就这么栽的。
# robocopy 原生支持长路径，退出码 0-7 都算成功。
function CopyTreeLong($from, $to) {
  $null = & robocopy $from $to /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1
  if ($LASTEXITCODE -ge 8) { throw "拷贝失败（robocopy $LASTEXITCODE）：$from" }
  $global:LASTEXITCODE = 0
}
foreach ($piece in @("node", "bin")) {
  $dest = Join-Path $AppDir $piece
  RemoveWithRetry $dest
  CopyTreeLong (Join-Path $Payload $piece) $dest
}
# dsh 的会话存储要 Node 22.15 才有的 zstd 接口。版本低了 dsh 一启动就抛
# 「does not provide an export named 'createZstdDecompress'」——表现是聊天完全
# 没反应，而入库还好好的（那条路直连 API 不经过 dsh），很难猜。
# 包是我们自己打的，装的时候确认一下，别让坏包静悄悄发出去。
$nodeVer = (& (Join-Path $NodeDir "node.exe") --version) -replace "^v", ""
if ([version]$nodeVer -lt [version]"22.15.0") {
  throw "这个安装包是坏的：里面带的运行环境太旧，装完聊天会用不了。去重新下载一份安装包再装。`n    （这行给站长看：包内 Node $nodeVer，需要 22.15 以上）"
}
# 拷完当场验一眼 dsh 是不是完整的。以前拷贝半途失败也照样往下走，
# 用户装完才发现聊天用不了，而且报错是英文的 ERR_MODULE_NOT_FOUND，没人看得懂。
$dshBoot = Join-Path $NodeDir "node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-app-boot"
$dshBin  = Join-Path $NodeDir "node_modules\@deepseek-ai\dsh\lib\bin.js"
# 缺文件不等于路径太长。有用户就装在 E:\ 根目录上，照样被告知
# 「把安装器放到路径短一点的地方」——已经不能再短了，他只会觉得这程序在胡说。
# 路径长不长自己量得出来，量完再决定该说哪句话。
$deep = $NodeDir.Length -gt 120
$fixHint = if ($deep) {
  "安装的位置太深（$NodeDir），文件拷到一半就断了。换个路径短的地方（比如 D:\ 根目录）再装一次。"
} else {
  "路径不长，那多半是拷贝时被杀毒软件拦了，或者磁盘满了。把安装目录加进杀毒软件白名单、腾出点空间，再装一次。"
}
if (-not (Test-Path $dshBin))  { throw "助手没装全（缺 dsh 主程序）。$fixHint" }
if (-not (Test-Path $dshBoot)) { throw "助手没装全（缺 dsh 的依赖）。$fixHint" }
Ok "运行环境就绪（$NodeDir，Node $nodeVer）"

Step "安放程序本体"
RemoveWithRetry $AppRepo
CopyTreeLong (Join-Path $Payload "app") $AppRepo
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
# 三个名字都试：运行期 ingest.js 就是 python/python3/py 轮着找的，
# 安装期口径得跟它一致，否则会出现「装的时候说没有、用的时候却有」。
# 而且不能只看 Get-Command 找不找得到 —— Windows 应用商店在 WindowsApps 下面
# 放了个同名的桩，跑起来只会弹商店。必须真问一次版本才算数。
# 挑哪个 python：优先挑 3.12 及以下的那个。
#
# 为什么不是「随便一个 3.9+」：认字组件 rapidocr-onnxruntime 在自己的元数据里写死了
# requires_python <3.13，pip 在 3.13/3.14 上根本装不上。有用户就栽在这儿——他有
# 一台装了 3.14 的机器，安装时老老实实选了「要支持扫描版 PDF」，装不上（黄字一闪
# 而过），然后传扫描书时程序还告诉他「重跑安装器选是就行」，他重跑了几遍都不行。
# 机器上要是同时有 3.12 和 3.14，挑前者两件事都办得成；只有 3.14 就照旧用，
# 普通 PDF 一点不受影响，只是下面那一步会直说装不了。
$PyExe = ""
$PyVer = $null
$PyFallback = ""
$PyFallbackVer = $null
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
  if ($major -eq 3 -and $minor -le 12) {                                 # 认字组件也能装的那一档
    $PyExe = $c.Source; $PyVer = @($major, $minor)
    break
  }
  if (-not $PyFallback) { $PyFallback = $c.Source; $PyFallbackVer = @($major, $minor) }
}
if (-not $PyExe -and $PyFallback) { $PyExe = $PyFallback; $PyVer = $PyFallbackVer }

if ($PyExe) {
  # 版本必须钉死。pymupdf4llm 从 1.27 起 import 时就硬 import onnxruntime（自带 OCR），
  # 而 onnxruntime 在不少 Windows 机器上 DLL load failed —— 实测本机 1.22/1.28 都起不来，
  # 结果是 import 直接崩、PDF 支持静默消失，报错用户完全看不懂。0.0.27 不碰它。
  # 底座也一起钉：只钉 pymupdf4llm 的话 pymupdf 会浮动到新版，等于没钉。
  # --user：装进用户自己的包目录，不碰系统站点目录，也不需要管理员。
  $pipPdf = Invoke-NativeSay $PyExe @("-m", "pip", "install", "--quiet", "--user", "--no-warn-script-location", "pymupdf4llm==0.0.27", "pymupdf==1.26.3")
  # 装完真 import 一次再说「就绪」—— 上面那个 onnxruntime 的坑正是「装上了但 import 就崩」
  # 直接拿返回码判，别再指望 $LASTEXITCODE 跨过函数调用还是原来那个
  $pdfProbe = Invoke-NativeSay $PyExe @("-c", "import pymupdf4llm; print('ok')")
  $pdfOk = $pdfProbe.Code -eq 0
  if ($pdfOk) {
    Ok "PDF 支持就绪（用你电脑上的 Python）"

    # ---- 扫描版 PDF（认字）----
    # 这一段以前只在联网安装器里有，离线包里没有。可现在官网发的就是这个包，
    # 结果是：从官网装的人永远读不了扫描件，而程序还会告诉他「重跑安装器、
    # 那一步选是」——他重跑一百遍也看不到那一步。所以补上。
    #
    # 这一步要联网（约 100 MB），而这本来是个「零下载」的离线包——所以它是
    # 问一句、默认不装、装不成也不影响任何其他东西。
    $ocrTooNew = ($PyVer -and ($PyVer[0] -gt 3 -or ($PyVer[0] -eq 3 -and $PyVer[1] -ge 13)))
    if ($ocrTooNew) {
      Write-Host ""
      Write-Host "   扫描版 PDF（认字）这一项装不了：你这台电脑上的 Python 是 $($PyVer[0]).$($PyVer[1])，" -ForegroundColor Yellow
      Write-Host "   而认字组件目前最高只支持到 3.12。普通 PDF、epub、txt 都不受影响。" -ForegroundColor Yellow
      Write-Host "   要读扫描件的话：去 python.org 另装一个 3.12（可以和现在这个共存），再重跑一次本安装器。" -ForegroundColor Yellow
      Write-Host ""
    } else {
      $wantOcr = "" + (Read-Host "   要支持扫描版 PDF 吗？这一步要联网再下约 100 MB (y/N)")
      if ($wantOcr -match "^[Yy]") {
        Write-Host "   正在装认字组件（大约 100 MB，慢的话请耐心等）..." -ForegroundColor DarkGray
        # 版本钉死，跟联网安装器里那条同一个理由：onnxruntime 新版在不少 Windows 机器上
        # DLL load failed；1.4.4 拉下来的是 1.18.1，实测能起。
        Invoke-Native $PyExe @("-m", "pip", "install", "--quiet", "--user", "--no-warn-script-location", "rapidocr-onnxruntime==1.4.4") | Out-Null
        $ocrProbe = Invoke-NativeSay $PyExe @("-c", "import rapidocr_onnxruntime; print('ok')")
        if ($ocrProbe.Code -eq 0) {
          Ok "扫描版 PDF 也能读了"
        } else {
          Write-Host "   认字组件没装成，扫描件暂时读不了；普通 PDF 不受影响。" -ForegroundColor Yellow
          Show-Why "它报的错：" $ocrProbe.Out
        }
      } else {
        Write-Host "   跳过了。以后想读扫描版的书，重跑一次本安装器，这一步选 y 就行。" -ForegroundColor DarkGray
      }
    }
  } else {
    Write-Host "   PDF 组件装上了但跑不起来，PDF 格式的书暂时读不了（epub/txt/docx 不受影响）。" -ForegroundColor Yellow
    Write-Host "   用的是这个 Python：$PyExe" -ForegroundColor DarkGray
    Show-Why "它报的错（把这几行发给站长就能定位）：" $pdfProbe.Out
    Write-Host "   常见原因：缺「Microsoft Visual C++ 运行库」（搜一下 vc_redist.x64.exe 装上），" -ForegroundColor Yellow
    Write-Host "   或者刚才下载组件时网没通。装好再重跑一次本安装器。" -ForegroundColor Yellow
  }
} else {

  Write-Host "   这台电脑没装 Python，PDF 格式的书暂时读不了（epub/txt/docx 不受影响）。" -ForegroundColor Yellow
  Write-Host "   想读 PDF：去 python.org 装一个 Python，再重跑一次本安装器就行。" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- Obsidian
# 译文是机器翻的，一定有要改的地方，而 Obsidian 读写的就是书库里那批 .md，
# 改完这边立刻看得到。所以它是默认装的一环，不是可选配件。
# 它是闭源软件，不能塞进我们的压缩包分发，只能从官方下载。
#
# 「装没装」不能靠猜路径：实测这台机器上 Obsidian 在 E:\Obsidian\，
# 装到别的盘很常见，查固定路径会把「已经装了」误判成没装，白下 316MB。
# 该问的是 obsidian:// 协议有没有人接——我们依赖的正是它。
Step "检查 Obsidian（用来自己改译文、做笔记）"
$ObsidianInstalled = $false
foreach ($root in @("HKCU:", "HKLM:")) {
  $cmd = (Get-ItemProperty "$root\SOFTWARE\Classes\obsidian\shell\open\command" -ErrorAction SilentlyContinue)."(default)"
  if ($cmd -match "obsidian") { $ObsidianInstalled = $true; break }
}
if ($ObsidianInstalled) {
  Ok "已经装过了"
} elseif ($ApiKey) {
  # 带参数跑 = 非交互（自动化/重装脚本），不在这儿停下来问
  Write-Host "   跳过 Obsidian（非交互安装）。" -ForegroundColor DarkGray
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
      curl.exe -fL --retry 2 --connect-timeout 25 -o "$env:TEMP\sf-obsidian.exe" $oasset.browser_download_url
      # GitHub 直连不通就走 gh-proxy.com 反代（原始地址整个跟在后面）
      if ($LASTEXITCODE -ne 0) {
        curl.exe -fL --retry 2 --connect-timeout 25 -o "$env:TEMP\sf-obsidian.exe" "https://gh-proxy.com/$($oasset.browser_download_url)"
      }
      if ($LASTEXITCODE -ne 0) { throw "Obsidian 没下下来（网络不通或者对方限速）" }
      Start-Process "$env:TEMP\sf-obsidian.exe" -ArgumentList "/S" -Wait
      Remove-Item -Force "$env:TEMP\sf-obsidian.exe" -ErrorAction SilentlyContinue
      $ObsidianInstalled = $true
      Ok "Obsidian 装好了"
    } catch {
      # 装不上不该拦住整个安装 —— 群星回廊本身完全能用
      # 这里捕到的可能是 .NET 抛的英文异常，原文只写进日志
      Write-Host "   Obsidian 这一步没装成。" -ForegroundColor Yellow
      Write-Host "   不影响使用：联网之后重新运行一次这个安装器就能补上。" -ForegroundColor Yellow
      Write-Host "   （这行给站长看：$($_.Exception.Message)）" -ForegroundColor DarkGray
    }
  }
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
# ---------------------------------------------------------------- 谁来当大脑
# 这一步必须排在问 key 前面。
#
# 以前这儿没有选择：不给一个 sk- 开头的 key 就出不去下面那个 while 循环，只能关窗口。
# 于是「我有 Codex / Claude 订阅，不想再去办一个 DeepSeek」的人根本装不进来——
# 而程序里 codex / 自带 Claude 账号那两条大脑，存在的全部意义就是给这种人用的。
# 门口那道坎正好把它们要服务的人挡在外面。
$brain = ""
if ($OldCfg -and $OldCfg.brain) { $brain = [string]$OldCfg.brain }
if ($GUI) { $brain = $GUI.Brain }        # 窗口里选过了，以它为准
if ($ApiKey -match "^sk-") { $brain = "dsh" }    # 带 key 的静默安装：意图已经写在参数里了
if (@("dsh","codex","cc") -notcontains $brain) {
  Step "谁来当大脑"
  Write-Host "   这个程序得有一个「大脑」替你干活。选一个："
  Write-Host "     1) 用我们代管的（推荐）     填一个 DeepSeek key，装完就能用"
  Write-Host "     2) 用我自己的 Codex 订阅    这台电脑上要先装好 Codex 并登录过"
  Write-Host "     3) 用我自己的 Claude 订阅   这台电脑上要先装好 Claude Code 并登录过"
  $pick = ""
  while (@("1","2","3") -notcontains $pick) {
    $pick = ("" + (Read-Host "   输 1 / 2 / 3（直接回车就是 1）")).Trim()
    if (-not $pick) { $pick = "1" }
    if (@("1","2","3") -notcontains $pick) { Write-Host "   只认 1、2、3 这三个数。" -ForegroundColor Yellow }
  }
  if ($pick -eq "2") { $brain = "codex" } elseif ($pick -eq "3") { $brain = "cc" } else { $brain = "dsh" }
}
if ($brain -ne "dsh") {
  # 只是提醒，不拦着装：命令没装好是几分钟就能补的事，
  # 为它把整个安装挡回去（用户还得从头再来一遍）不划算。
  $__need = "claude"; if ($brain -eq "codex") { $__need = "codex" }
  $__found = $null
  try { $__found = Get-Command $__need -ErrorAction SilentlyContinue } catch {}
  if ($__found) { Ok "找到 $__need 了，装完就用你自己的账号" }
  else {
    Write-Host "   这台电脑上还没有 $__need 命令。" -ForegroundColor Yellow
    Write-Host "   装完之后先把它装好并登录，回廊才有得用；也可以到设置页改回「内置助手」（那条要填 key）。" -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------- API key
try { Stop-Transcript | Out-Null } catch {}
Step "配置 DeepSeek"
# 次序：命令行显式传的 > 上次存的 > 问用户。
# 反过来的话，用户想换 key 而特地带 -ApiKey 重装，会被老 key 默默盖掉。
if ($brain -ne "dsh") {
  # 用自己订阅的人不经过我们代管的 key。老 key 有就留着——他哪天在设置页
  # 换回「内置助手」时还用得上，这会儿抹掉只会让那一步凭空多一道坎。
  $key = $OldKey
  Ok "用你自己的账号，装的时候不用填 DeepSeek key"
} elseif ($GUI) {
  # 窗口里已经填过了（留空就是「沿用上次那把」），不再问第二遍
  $key = $GUI.Key
  if (-not $key) { $key = $OldKey }
} elseif ($ApiKey -match "^sk-") {
  $key = $ApiKey
} elseif ($OldKey) {
  $key = $OldKey
  Ok "沿用你上次填的 key（想换成别的：删掉 $ConfigPath 再装一遍）"
} else {
  Write-Host "   需要一个 DeepSeek API key（在 platform.deepseek.com 注册后创建，sk- 开头）。"
  Write-Host "   粘贴时屏幕上不会显示，这是正常的——粘完直接回车。" -ForegroundColor DarkGray
  $key = ""
  $keyTries = 0
  while (-not ($key -match "^sk-")) {
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
if ($key) { $__env["DEEPSEEK_API_KEY"] = $key }
$config["vaultPath"] = $Vault
if (-not $config["port"]) { $config["port"] = 7787 }
$config["token"] = $token
$config["brain"] = $brain
$config["env"]   = $__env
# 无 BOM UTF-8：server.js 的 JSON.parse 见到 BOM 会当首次运行，key 就"丢"了
[System.IO.File]::WriteAllText($ConfigPath, ($config | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
$key = $null
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch {}
Ok "配置写好了"

# ---------------------------------------------------------------- 自动更新器（有网时用，没网静默跳过）
Step "安装自动更新器"
$Owner = "URaux"; $Repo = "shufang"
# 国内源。装机的人在国内，GitHub 时通时不通，自己在 Cloudflare R2 上放了一份
# （download.gnosaria.com，国内可达），GitHub 兜底。两条安装路径的更新器必须一致，
# 否则「已经发布了」这句话对一半用户是假的。
$MirrorBase = "https://download.gnosaria.com/shufang"
$UpdaterPath = Join-Path $AppDir "update.ps1"
$updaterText = @"
`$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
`$AppDir  = "$AppDir"
`$AppRepo = "$AppRepo"
`$ShaFile = Join-Path `$AppDir ".app-sha"
try {
  # 版本号先问国内源，问不到再问 GitHub
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
  # sha 和包必须同源：`$latest 待会要写进 .app-sha，写了跟实际装的包对不上的 sha，
  # 下次启动会比出「已是最新」，用户永远卡在这一版还收不到任何提示。
  # 所以版本号哪来的、包就哪来的；国内源的包没拿到才回 GitHub，回退时 sha 也重新问一次。
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
rem 全量包默认没装 Obsidian，装了的话取消下一行的 rem 即可
rem start "" "obsidian://open?path=$([uri]::EscapeDataString($Vault))"
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
Write-Host "  程序在: $AppDir" -ForegroundColor Green
Write-Host "  书库在: $Vault" -ForegroundColor Green
Write-Host "  双击桌面「启动群星回廊」开始用。" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  如果之后启动出问题，双击桌面的『复制群星回廊日志』就能把日志复制到剪贴板。" -ForegroundColor Yellow
try { Stop-Transcript | Out-Null } catch {}
if (-not ($InstallDir -and $ApiKey)) { Read-Host "按回车关闭本窗口" }
