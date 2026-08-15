' 群星阅览室 启动器（无黑窗版）
' 由安装器生成实体文件，占位符会被替换成真实路径。
' 做的事：静默跑更新 → 起服务 → 等端口通 → 开浏览器。
' 出错才弹窗说人话，正常情况下用户只看到浏览器打开。
Option Explicit
Dim sh, fso, appDir, appRepo, nodeDir, binDir, port, url, i, ok
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

appDir  = "__APPDIR__"
appRepo = appDir & "\app"
nodeDir = appDir & "\node"
binDir  = appDir & "\bin"

If Not fso.FolderExists(appRepo) Then
  MsgBox "找不到程序文件夹，可能是安装没完成。" & vbCrLf & _
         "请重新运行一次安装程序。" & vbCrLf & vbCrLf & appRepo, 16, "群星阅览室"
  WScript.Quit 1
End If

' 已经开着就直接开浏览器，不重复启动
port = 7787
If fso.FileExists(appDir & "\last-port") Then
  On Error Resume Next
  port = CInt(Trim(fso.OpenTextFile(appDir & "\last-port", 1).ReadAll))
  If Err.Number <> 0 Then port = 7787
  On Error GoTo 0
End If

' 静默检查更新（失败不挡启动）
On Error Resume Next
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & appDir & "\update.ps1""", 0, True
On Error GoTo 0

' 起服务：0 = 不显示窗口
sh.CurrentDirectory = appRepo & "\webapp"
sh.Environment("PROCESS")("PATH") = nodeDir & ";" & binDir & ";" & sh.ExpandEnvironmentStrings("%PATH%")
sh.Run """" & nodeDir & "\node.exe"" server.js", 0, False

' 等端口起来（最多 40 秒），期间不打扰用户
ok = False
For i = 1 To 40
  WScript.Sleep 1000
  If fso.FileExists(appDir & "\last-port") Then
    On Error Resume Next
    port = CInt(Trim(fso.OpenTextFile(appDir & "\last-port", 1).ReadAll))
    On Error GoTo 0
  End If
  On Error Resume Next
  Dim http
  Set http = CreateObject("MSXML2.XMLHTTP")
  http.Open "GET", "http://localhost:" & port & "/api/status", False
  http.Send
  If Err.Number = 0 And http.Status = 200 Then ok = True
  Err.Clear
  On Error GoTo 0
  If ok Then Exit For
Next

If ok Then
  sh.Run "http://localhost:" & port & "/", 1, False
Else
  MsgBox "启动超时了。" & vbCrLf & vbCrLf & _
         "多半是第一次启动在装组件，稍等一分钟再双击一次就好。" & vbCrLf & _
         "还不行的话，把这个文件发给帮你装的人：" & vbCrLf & _
         sh.ExpandEnvironmentStrings("%TEMP%") & "\shufang-install.log", 48, "群星阅览室"
End If
