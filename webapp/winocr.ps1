# 备用认字：完全用 Windows 自带的东西读扫描版 PDF。
#
# 为什么要有这一条路：
# 主力那条是 Python + rapidocr-onnxruntime，装起来要 pip 联网、要对的 Python 版本、
# 还要 VC++ 运行库。这三样任何一样不成，用户就彻底读不了扫描件——而且他往往什么
# 也做不了：公司网掐着 pip、Python 是 3.14、装不上运行库。实测有用户来回折腾一下午
# 也没装上。
#
# 而 Windows 10/11 自己就带着两样东西：
#   Windows.Data.Pdf   —— 把 PDF 页渲染成位图
#   Windows.Media.Ocr  —— 认字（中文简体和英文在中文系统上一般都现成）
# 零下载、零依赖、不碰 Python。认得比 rapidocr 糙一点，但「糙一点」和「读不了」
# 之间的差距，比「糙一点」和「准一点」之间大得多。
#
# 用法：
#   powershell -NoProfile -File winocr.ps1 -Pdf <文件> [-Lang zh-Hans-CN] [-Width 2000]
# 输出：正文走 stdout；进度走 stderr，一行一个 "PAGE n/total"，跟 Python 那条对齐，
# 上层（ingest.js）两条路用同一套进度解析。
param(
  # 不能写 Mandatory：只传 -Probe 的时候 PowerShell 会停下来向终端要参数，
  # 而我们是从程序里无人值守地调它——那就是一直挂着。必填与否自己在下面判。
  [string]$Pdf = "",
  [string]$Lang = "",
  [int]$Width = 2000,
  [switch]$Probe          # 只报「这台机器行不行」，不干活
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# WinRT 的异步在 PowerShell 5.1 里得自己接一手：把 IAsyncOperation 转成 .NET Task 再等。
# 这段反射是固定写法，别改。
Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
function Await($op, $type) {
  $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
  $t.Wait(-1) | Out-Null
  $t.Result
}
$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.FullName -eq 'Windows.Foundation.IAsyncAction'
})[0]
function AwaitAction($action) {
  $t = $asTaskAction.Invoke($null, @($action))
  $t.Wait(-1) | Out-Null
}

# 这几行「用不到的」类型加载不能省：不先碰一下，下面 [Windows.…] 的类型名解析不出来
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfDocument, Windows.Data, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

function Get-Engine([string]$tag) {
  if ($tag) {
    try {
      $l = [Windows.Globalization.Language]::new($tag)
      $e = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($l)
      if ($e) { return $e }
    } catch { }
  }
  # 没指定、或者指定的那门语言这台机器没装：用系统语言那一套
  return [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
}

if ($Probe) {
  $tags = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
  $e = Get-Engine $Lang
  if ($e) { Write-Output ("OK " + ($tags -join ",")) } else { Write-Output "NO" }
  exit 0
}

if (-not $Pdf) { Write-Error "没给 -Pdf"; exit 2 }
if (-not (Test-Path -LiteralPath $Pdf)) { Write-Error "找不到文件: $Pdf"; exit 2 }
$engine = Get-Engine $Lang
if (-not $engine) { Write-Error "这台电脑没有可用的 OCR 语言包"; exit 3 }

$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync((Resolve-Path -LiteralPath $Pdf).Path)) ([Windows.Storage.StorageFile])
$doc = Await ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
$total = $doc.PageCount
[Console]::Error.WriteLine("PAGE 0/$total")

for ($i = 0; $i -lt $total; $i++) {
  $page = $doc.GetPage($i)
  $stream = [Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
  # 渲染宽度直接决定认得准不准：原样渲染（一般 600-800 px 宽）中文小字基本认不出，
  # 拉到 2000 px 才够。再高只是更慢，收益很小。
  $opt = [Windows.Data.Pdf.PdfPageRenderOptions]::new()
  $opt.DestinationWidth = [uint32]$Width
  AwaitAction ($page.RenderToStreamAsync($stream, $opt))
  $stream.Seek(0) | Out-Null

  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bmp = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $res = Await ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])

  # 一行一行拼：Text 属性本身是整页一串，行信息更贴近版面
  $lines = @($res.Lines | ForEach-Object { ($_.Words | ForEach-Object { $_.Text }) -join "" })
  Write-Output ("<<<PAGE " + ($i + 1) + ">>>")
  if ($lines.Count) { $lines | ForEach-Object { Write-Output $_ } }

  $bmp.Dispose()
  $stream.Dispose()
  # WinRT 的 IClosable 到 .NET 这边叫 Dispose，不是 Close
  $page.Dispose()
  [Console]::Error.WriteLine("PAGE " + ($i + 1) + "/$total")
}
