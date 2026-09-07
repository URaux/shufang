# 群星回廊 · 更新并重启
#
# 由设置页那颗「更新并重启」按钮调起，**必须在程序目录之外运行**：
# 更新的动作是把整个 app\ 挪走再换上新的，脚本自己待在里面就会被一起挪掉。
# 所以程序会把这份拷到 ~/.shufang\ 下再执行。
#
# 顺序是死的，不能改：
#   1. 等服务进程真的退出——服务是从 app\ 里跑起来的，还活着就挪不动那个目录
#      （Windows 直接拒绝；就算侥幸挪成功，进程里跑的还是旧代码，网页要的文件却已经不在原路径，
#       用户看到的是页面突然全白）
#   2. 起桌面启动器。更新这一步交给它做——它开头本来就要跑一遍 update.ps1，
#      跑完再起服务、开浏览器。少写一条更新逻辑，就少一条会跟启动器走岔的逻辑。
#
# 任何一步失败都不许把用户卡在"没有程序可用"的状态：等超时就照样起启动器，
# 大不了这次没更新成，下次启动再更新。
param(
  [Parameter(Mandatory = $true)][int]$ServerPid,
  [Parameter(Mandatory = $true)][string]$AppDir
)
$ErrorActionPreference = "SilentlyContinue"

# 最多等 30 秒。正常情况下服务收到请求后一两秒就自己退了。
for ($i = 0; $i -lt 60; $i++) {
  if (-not (Get-Process -Id $ServerPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 500
}
# 进程没了不等于文件句柄立刻释放，多给一拍
Start-Sleep -Milliseconds 800

$vbs = Join-Path $AppDir "启动.vbs"
if (Test-Path $vbs) {
  Start-Process "wscript.exe" -ArgumentList ('"' + $vbs + '"')
} else {
  # 没有启动器（比如开发机上直接 node 起的），退回自己更新 + 自己起服务
  $upd = Join-Path $AppDir "update.ps1"
  if (Test-Path $upd) { & powershell -NoProfile -ExecutionPolicy Bypass -File $upd }
  $node = Join-Path $AppDir "node\node.exe"
  $srv = Join-Path $AppDir "app\webapp\server.js"
  if ((Test-Path $node) -and (Test-Path $srv)) {
    Start-Process $node -ArgumentList ('"' + $srv + '"') -WorkingDirectory (Split-Path $srv)
  }
}
