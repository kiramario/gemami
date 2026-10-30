# ============================================================================
# ArchiveBatchExtract.ps1  —— 批量解压工具
# 功能: 批量解压一个文件夹内的所有压缩文件, 支持多密码逐个尝试,
#       默认解压到压缩文件同一目录, 也可指定统一输出路径。
# 依赖: 7-Zip (7z.exe)。未打包运行时自带日志回退; 嵌入 Main.ps1 时走全局 OutputLog。
# ============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 日志函数 ----------
# 委托给 Write-ToolLog: 嵌入模式(Main.ps1 加载)→ 全局 OutputLog
#                       独立模式 → _logs/ArchiveBatchExtract_yyyyMMdd.log (见顶部 fallback)
# 注意: 函数名不能用 Write-Log, 否则 dot-source 加载时会覆盖 Main.ps1 的同名全局函数,
#       导致 Write-ToolLog -> Write-Log -> Write-ToolLog 无限递归 (CallDepthOverflow)。
function Write-BaeLog {
    param([string]$Message, [string]$Type = "Info")
    Write-ToolLog $Message $Type
}

# 独立模式日志 fallback: 仅当未嵌入 Main.ps1 时启用
if (-not (Get-Command Write-ToolLog -ErrorAction SilentlyContinue)) {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $script:LogName = "ArchiveBatchExtract"
    $logDir = Join-Path $script:ScriptDir '_logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
    }
    $script:LogFile = Join-Path $logDir ($script:LogName + '_' + (Get-Date -Format 'yyyyMMdd') + '.log')
    function Write-ToolLog {
        param([string]$Message, [string]$Type = "Info")
        $ts = Get-Date -Format 'HH:mm:ss'
        $line = "[$ts] [$Type] $Message"
        $line | Out-File -LiteralPath $script:LogFile -Append -Encoding UTF8
        Write-Host $line
    }
    Write-ToolLog "独立模式日志就绪: $script:LogFile" 'Info'
}

# ---------- 脚本级变量 ----------
# 注意: BackgroundWorker 在后台线程运行, 不能直接读取 WPF 控件 (.Text), 否则跨线程异常。
# 因此点击「开始」时在 UI 线程把控件值捕获到以下普通变量, 后台逻辑只读取这些变量。
$script:SevenZip      = $null
$script:Abort         = $false
$script:BgWorker      = $null
$script:Default7zPath = "E:\portable\PortableApps\7-ZipPortable\App\7-Zip\7z.exe"

# 由 UI 线程捕获的输入
$script:SevenZipPath  = $null
$script:SrcDir        = $null
$script:PasswordText  = $null
$script:ExtsText      = $null
$script:Recurse       = $false
$script:CustomMode    = $false
$script:OutDir        = $null

# ---------- 辅助函数 ----------

# 在 UI 线程上执行(供后台线程回调使用)
# 在 UI 线程执行脚本块。
# ★ 参数通过 ArgumentList 显式传入, 不依赖闭包捕获外部局部变量
#   (闭包变量在跨作用域/跨线程时会变成 $null, 导致日志等内容"消失")。
function Invoke-OnUiThread {
    param([ScriptBlock]$ScriptBlock, [object[]]$ArgumentList = @())
    if ($null -eq $script:ui -or $script:ui.Dispatcher.CheckAccess()) {
        & $ScriptBlock @ArgumentList
    }
    else {
        $script:ui.Dispatcher.Invoke([System.Action]{
                param($sb, $args2)
                & $sb @args2
            }, [object[]]@($ScriptBlock, $ArgumentList)) | Out-Null
    }
}

# 带颜色的日志输出
function Add-BaeLog {
    param([string]$Message, [string]$Type = "Info")
    $ts  = Get-Date -Format 'HH:mm:ss'
    $tag = switch ($Type) {
        "Info"    { "INFO" }
        "Warning" { "WARN" }
        "Error"   { "ERR " }
        "Success" { " OK " }
        default   { "INFO" }
    }
    $color = switch ($Type) {
        "Error"    { "#FF6B6B" }
        "Warning"  { "#FFD93D" }
        "Success"  { "#6BCB77" }
        default    { "#D0D0D0" }
    }
    # ★ 日志由后台线程调用, 容错处理: 绝不让"记日志"中断解压任务
    try { & $script:fnWriteLog $Message -Type $Type }
    catch { }
    # ★ 必须显式传参: ScriptBlock 内直接引用外部局部变量时, 跨作用域会变成 $null
    try { & $script:fnAppendBaeLog ("[$ts] [$tag] $Message") $color }
    catch { }
}

# 把一行日志追加到 UI 列表(统一入口)
function Append-BaeLogLine {
    param([string]$Text, [string]$Color)
    $action = {
        param($t, $c)
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content   = $t
        $item.Foreground = $c
        # Items.Add 会返回索引 int, 必须抑制
        [void]$script:lstLog.Items.Add($item)
        $script:lstLog.ScrollIntoView($item)
    }
    # ★ 必须用 -ArgumentList 传数组, 否则第 2 个形参 [object[]] 会把参数吞掉
    & $script:fnInvokeOnUi $action -ArgumentList @($Text, $Color)
}

# 更新进度条
function Update-BaeProgress {
    param([int]$Done, [int]$Total)
    $action = {
        param($d, $t)
        if ($t -le 0) { $script:prgBar.Value = 0; $script:txtProgress.Text = "就绪" }
        else {
            $script:prgBar.Value = [int](($d / $t) * 100)
            $script:txtProgress.Text = "$d / $t  ($($script:prgBar.Value)%)"
        }
    }
    & $script:fnInvokeOnUi $action -ArgumentList @($Done, $Total)
}

# 查找 7z.exe (从 Ctx.Config 读取, 兼容独立 Runspace)
function Find-SevenZip {
    param($Ctx)
    if (-not $Ctx) { $Ctx = $script:Ctx }
    $candidates = @(
        $Ctx.Config.SevenZipPath,
        $Ctx.Config.Default7zPath,
        "E:\portable\PortableApps\7-ZipPortable\7z.exe",
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        (Join-Path $env:LOCALAPPDATA "Programs\7-Zip\7z.exe")
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
            return $c
        }
    }
    return $null
}

# 解析密码列表(每行/逗号/分号分隔, 去除空白)
function Parse-Passwords {
    param([string]$Text)
    return ($Text -split "[\r\n,;]+" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_.Length -gt 0 })
}

# 解析扩展名(支持 .zip / zip, 统一转为小写带点)
function Parse-Exts {
    param([string]$Text)
    $raw = ($Text -split "[\r\n,; ]+" | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $res = @()
    foreach ($e in $raw) {
        if (-not $e.StartsWith('.')) { $e = '.' + $e }
        $res += $e
    }
    return $res
}

# 启动外部进程但不阻塞; 异步排空 stdout/stderr, 避免管道缓冲区填满导致子进程卡死
function Start-AsyncProcess {
    param([string]$Exe, [string]$ArgLine)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = $ArgLine
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    try { $p.BeginOutputReadLine() } catch { }
    try { $p.BeginErrorReadLine() } catch { }
    return $p
}

# 调用 7z 解压单个文件(非阻塞, 返回 Process 对象供状态机轮询)
function Invoke-Extract {
    param([string]$Archive, [string]$OutDir, [string]$Password, $Ctx)
    if (-not $Ctx) { $Ctx = $script:Ctx }
    $sevenZip = $Ctx.Config.SevenZipPath
    $argList = [System.Collections.Generic.List[string]]::new()
    [void]$argList.Add('x')                       # 完整路径解压
    [void]$argList.Add("`"$Archive`"")
    [void]$argList.Add("-o`"$OutDir`"")
    [void]$argList.Add('-y')                      # 全部 yes
    if ($Password -ne '') { [void]$argList.Add("-p`"$Password`"") }
    return & $script:fnStartAsyncProc -Exe $sevenZip -ArgLine ($argList -join ' ')
}

# ---------- 选择对话框 ----------
function Select-Folder {
    param([string]$Initial)
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "选择文件夹"
    $dlg.ShowNewFolderButton = $true
    if ($Initial -and (Test-Path -LiteralPath $Initial)) { $dlg.SelectedPath = $Initial }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

function Select-7zExe {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "7z 可执行文件 (7z.exe)|7z.exe|所有 exe (*.exe)|*.exe"
    $dlg.Title = "选择 7z.exe"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}

# ---------- 核心: 批量解压 ----------
# ★ 同 VideoSlim: 全部在 UI 线程运行, 由 DispatcherTimer 推进状态机, 不使用 Runspace。
#   每个压缩包可能要依次尝试多个密码, 因此状态机是「文件 -> 密码尝试」两层。
function Start-BatchExtract {
    $seven = & $script:fnFindSevenZip -Ctx $script:Ctx
    if (-not $seven) {
        & $script:fnAddBaeLog "未找到 7z.exe, 请在上方指定 7z.exe 路径。" 'Error'
        return
    }
    $script:SevenZip = $seven
    & $script:fnAddBaeLog "使用 7z: $seven" 'Info'

    $src = $script:SrcDir
    if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src -PathType Container)) {
        & $script:fnAddBaeLog "源文件夹不存在或未选择。" 'Error'
        return
    }

    $exts = & $script:fnParseExts $script:ExtsText
    if ($exts.Count -eq 0) { & $script:fnAddBaeLog "未配置有效的文件类型。" 'Error'; return }

    $recurse = $script:Recurse
    $files = @(Get-ChildItem -Path $src -File -Recurse:$recurse |
        Where-Object { $exts -contains $_.Extension.ToLower() })

    if ($files.Count -eq 0) {
        & $script:fnAddBaeLog "未在源文件夹中找到匹配的压缩文件。" 'Warning'
        return
    }
    & $script:fnAddBaeLog ("找到 {0} 个压缩文件 (递归={1}, 类型={2})" -f $files.Count, $recurse, ($exts -join ' ')) 'Info'

    $pwds = & $script:fnParsePasswords $script:PasswordText
    & $script:fnAddBaeLog ("密码策略: 先尝试无密码, 再依次尝试 {0} 个密码。" -f $pwds.Count) 'Info'

    if ($script:CustomMode) {
        $outBase = $script:OutDir
        if ([string]::IsNullOrWhiteSpace($outBase) -or -not (Test-Path -LiteralPath $outBase -PathType Container)) {
            & $script:fnAddBaeLog "自定义输出路径无效, 请先选择。" 'Error'
            return
        }
    }

    # 初始化状态机
    $script:BaeFiles      = $files
    $script:BaeTotal      = $files.Count
    $script:BaeIdx        = 0
    $script:BaeAttempts   = @('') + $pwds
    $script:BaeAttemptIdx = 0
    $script:BaeProc       = $null
    $script:BaeDone       = 0
    $script:BaeSuccess    = 0
    $script:BaeFailed     = 0
    $script:BaeFailedList = [System.Collections.ArrayList]::new()
    $script:BaeAbort      = $false

    & $script:fnStepBatch
    $script:BgTimer.Start()
}

# 状态机的一步: 结算已结束的 7z 进程 -> 决定是否换密码重试 / 进入下一个文件
function Step-Batch {
    try {
        # 1) 结算上一个进程
        if ($script:BaeProc) {
            if (-not $script:BaeProc.HasExited) { return }

            $code  = $script:BaeProc.ExitCode
            $f     = $script:BaeCur
            $used  = $script:BaeAttemptIdx
            $total = $script:BaeTotal
            $script:BaeProc = $null

            if ($code -eq 0) {
                $script:BaeSuccess++
                if ($used -eq 0) {
                    & $script:fnAddBaeLog ("✓ {0} 解压成功 (无密码)" -f $f.Name) 'Success'
                }
                else {
                    & $script:fnAddBaeLog ("✓ {0} 解压成功 (密码 #{1})" -f $f.Name, $used) 'Success'
                }
            }
            else {
                # 还有密码没试 -> 用下一个密码重试同一个文件
                if ($script:BaeAttemptIdx -lt ($script:BaeAttempts.Count - 1)) {
                    $script:BaeAttemptIdx++
                    & $script:fnStartBaeAttempt
                    return
                }
                $script:BaeFailed++
                [void]$script:BaeFailedList.Add($f.Name)
                & $script:fnAddBaeLog ("✗ {0} 解压失败 (密码不正确或文件损坏)" -f $f.Name) 'Error'
            }

            $script:BaeDone++
            & $script:fnUpdateProgress $script:BaeDone $total
        }

        # 2) 中止或全部完成
        if ($script:BaeAbort) {
            $script:BgTimer.Stop()
            & $script:fnAddBaeLog "用户已中止任务。" 'Warning'
            & $script:fnFinishBatch
            return
        }
        if ($script:BaeIdx -ge $script:BaeFiles.Count) {
            $script:BgTimer.Stop()
            & $script:fnFinishBatch
            return
        }

        # 3) 开始下一个文件(从无密码开始)
        $f = $script:BaeFiles[$script:BaeIdx]
        $script:BaeIdx++
        $script:BaeAttemptIdx = 0
        $script:BaeCur = $f

        if ($script:CustomMode) { $outDir = Join-Path $script:OutDir $f.BaseName }
        else { $outDir = $f.DirectoryName }
        if (-not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Force -Path $outDir -ErrorAction SilentlyContinue | Out-Null
        }
        $script:BaeOutDir = $outDir
        & $script:fnStartBaeAttempt
    }
    catch {
        & $script:fnAddBaeLog "执行异常: $($_.Exception.Message)" 'Error'
        $script:BgTimer.Stop()
        & $script:fnFinishBatch
    }
}

# 用当前密码启动一次 7z 解压(不阻塞)
function Start-BaeAttempt {
    $f = $script:BaeCur
    $p = $script:BaeAttempts[$script:BaeAttemptIdx]
    $script:BaeProc = & $script:fnInvokeExtract -Archive $f.FullName -OutDir $script:BaeOutDir -Password $p -Ctx $script:Ctx
}

# 收尾: 汇总并恢复按钮
function Finish-Batch {
    & $script:fnAddBaeLog ("========== 完成: 成功 {0}, 失败 {1} / 共 {2} ==========" -f $script:BaeSuccess, $script:BaeFailed, $script:BaeTotal) 'Success'
    if ($script:BaeFailedList.Count -gt 0) {
        & $script:fnAddBaeLog ("失败列表: " + ($script:BaeFailedList -join ', ')) 'Error'
    }
    $script:btnStart.IsEnabled = $true
    $script:btnStop.IsEnabled  = $false
    $script:prgBar.Value = 0
    $script:txtProgress.Text = "就绪"
}

# ============================================================================
# UI (XAML)
# ============================================================================
$xaml = @'
<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              Background="#1E1E1E" Padding="16">
  <StackPanel>
    <TextBlock Text="批量解压工具 (7-Zip)" FontSize="20" FontWeight="Bold" Foreground="#4FC3F7" Margin="0,0,0,12"/>

    <!-- 7z 路径 -->
    <TextBlock Text="7-Zip 可执行文件 (7z.exe)" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <Grid Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="Txt7zPath" Grid.Column="0" Background="#2D2D2D" Foreground="#FFFFFF"
               BorderBrush="#455A64" Padding="6"/>
      <Button x:Name="BtnBrowse7z" Grid.Column="1" Content="浏览..." Margin="6,0,0,0"
              Background="#37474F" Foreground="#FFFFFF" Padding="10,4" BorderThickness="0"/>
    </Grid>

    <!-- 源文件夹 -->
    <TextBlock Text="源文件夹 (包含要解压的压缩文件)" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <Grid Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="TxtSourceDir" Grid.Column="0" Background="#2D2D2D" Foreground="#FFFFFF"
               BorderBrush="#455A64" Padding="6"/>
      <Button x:Name="BtnBrowseSource" Grid.Column="1" Content="选择..." Margin="6,0,0,0"
              Background="#37474F" Foreground="#FFFFFF" Padding="10,4" BorderThickness="0"/>
    </Grid>

    <!-- 密码 -->
    <TextBlock Text="密码列表 (每行一个, 自动尝试「无密码」+ 以下所有密码)" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <TextBox x:Name="TxtPasswords" Height="80" AcceptsReturn="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" Background="#2D2D2D" Foreground="#FFFFFF"
             BorderBrush="#455A64" Padding="6" Margin="0,0,0,8"/>

    <!-- 输出位置 -->
    <TextBlock Text="输出位置" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
      <RadioButton x:Name="RdoSameDir" Content="解压到压缩文件同一目录" GroupName="OutMode"
                   IsChecked="True" Foreground="#FFFFFF" Margin="0,0,16,0" VerticalAlignment="Center"/>
      <RadioButton x:Name="RdoCustomDir" Content="解压到指定路径" GroupName="OutMode"
                   Foreground="#FFFFFF" VerticalAlignment="Center"/>
    </StackPanel>
    <Grid Margin="0,4,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="TxtOutDir" Grid.Column="0" Background="#2D2D2D" Foreground="#FFFFFF"
               BorderBrush="#455A64" Padding="6" IsEnabled="False"/>
      <Button x:Name="BtnBrowseOut" Grid.Column="1" Content="选择..." Margin="6,0,0,0"
              Background="#37474F" Foreground="#FFFFFF" Padding="10,4" BorderThickness="0" IsEnabled="False"/>
    </Grid>

    <!-- 选项 -->
    <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
      <CheckBox x:Name="ChkRecurse" Content="递归子文件夹" IsChecked="False"
                Foreground="#FFFFFF" VerticalAlignment="Center" Margin="0,0,20,0"/>
      <TextBlock Text="文件类型:" Foreground="#B0BEC5" VerticalAlignment="Center" Margin="0,0,6,0"/>
      <TextBox x:Name="TxtExts" Width="320" Background="#2D2D2D" Foreground="#FFFFFF"
               BorderBrush="#455A64" Padding="6"
               Text=".zip,.7z,.rar,.tar,.gz,.tgz,.bz2,.tbz2,.xz,.txz,.zst,.wim,.iso,.cab,.lzma"/>
    </StackPanel>

    <!-- 操作按钮 -->
    <StackPanel Orientation="Horizontal" Margin="0,4,0,10">
      <Button x:Name="BtnStart" Content="开始解压" Background="#2E7D32" Foreground="#FFFFFF"
              Padding="16,8" BorderThickness="0" FontWeight="Bold"/>
      <Button x:Name="BtnStop" Content="停止" Background="#C62828" Foreground="#FFFFFF"
              Padding="16,8" BorderThickness="0" Margin="10,0,0,0" IsEnabled="False"/>
      <Button x:Name="BtnClearLog" Content="清空日志" Background="#37474F" Foreground="#FFFFFF"
              Padding="14,8" BorderThickness="0" Margin="10,0,0,0"/>
    </StackPanel>

    <!-- 进度 -->
    <ProgressBar x:Name="PrgBar" Height="18" Minimum="0" Maximum="100" Value="0"
                 Background="#2D2D2D" Foreground="#4FC3F7" Margin="0,0,0,4"/>
    <TextBlock x:Name="TxtProgress" Text="就绪" Foreground="#B0BEC5" Margin="0,0,0,8"/>

    <!-- 日志 -->
    <TextBlock Text="日志" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <ListBox x:Name="LstLog" Height="200" Background="#161616" Foreground="#D0D0D0"
             BorderBrush="#455A64" FontFamily="Consolas" ScrollViewer.VerticalScrollBarVisibility="Auto"/>
  </StackPanel>
</ScrollViewer>
'@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$ui = [Windows.Markup.XamlReader]::Load($reader)

# 绑定控件引用
$script:ui            = $ui
$script:txt7zPath     = $ui.FindName("Txt7zPath")
$script:txtSourceDir  = $ui.FindName("TxtSourceDir")
$script:txtPasswords  = $ui.FindName("TxtPasswords")
$script:rdoSameDir    = $ui.FindName("RdoSameDir")
$script:rdoCustomDir  = $ui.FindName("RdoCustomDir")
$script:txtOutDir     = $ui.FindName("TxtOutDir")
$script:chkRecurse    = $ui.FindName("ChkRecurse")
$script:txtExts       = $ui.FindName("TxtExts")
$script:btnStart      = $ui.FindName("BtnStart")
$script:btnStop       = $ui.FindName("BtnStop")
$script:btnClearLog   = $ui.FindName("BtnClearLog")
$script:prgBar        = $ui.FindName("PrgBar")
$script:txtProgress   = $ui.FindName("TxtProgress")
$script:lstLog        = $ui.FindName("LstLog")

# 日志委托(指向全局 Write-ToolLog, 避免递归)
$script:fnWriteLog = (Get-Command Write-ToolLog).ScriptBlock

# ---------- 函数委托绑定 ----------
# ★ 关键: Main.ps1 用 . $scriptPath (dot-source) 加载本脚本, 普通 function 会定义进
#   Set-Tool 的局部作用域, 该函数返回后作用域销毁, 事件回调(之后才触发)就找不到它们。
#   因此必须绑定到 $script: 作用域并用 & $script:fnXxx 调用。
$script:fnAddBaeLog      = (Get-Command Add-BaeLog).ScriptBlock
$script:fnAppendBaeLog   = (Get-Command Append-BaeLogLine).ScriptBlock
$script:fnUpdateProgress  = (Get-Command Update-BaeProgress).ScriptBlock
$script:fnFindSevenZip    = (Get-Command Find-SevenZip).ScriptBlock
$script:fnParsePasswords  = (Get-Command Parse-Passwords).ScriptBlock
$script:fnParseExts       = (Get-Command Parse-Exts).ScriptBlock
$script:fnInvokeExtract   = (Get-Command Invoke-Extract).ScriptBlock
$script:fnSelectFolder    = (Get-Command Select-Folder).ScriptBlock
$script:fnSelect7z        = (Get-Command Select-7zExe).ScriptBlock
$script:fnStartBatch      = (Get-Command Start-BatchExtract).ScriptBlock
$script:fnStepBatch       = (Get-Command Step-Batch).ScriptBlock
$script:fnFinishBatch     = (Get-Command Finish-Batch).ScriptBlock
$script:fnStartBaeAttempt = (Get-Command Start-BaeAttempt).ScriptBlock
$script:fnStartAsyncProc  = (Get-Command Start-AsyncProcess).ScriptBlock
$script:fnInvokeOnUi      = (Get-Command Invoke-OnUiThread).ScriptBlock

# 状态机计时器(UI 线程): 轮询 7z 子进程并推进
$script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(300)
# ★ 同 VideoSlim: 脚本块挂在计时器自身的 Tag 上(CLR 属性),
#   避免 $script: 作用域被回收后 & $null 抛 BadExpression。
$script:BgTimer.Tag = (Get-Command Step-Batch).ScriptBlock
$script:BgTimer.Add_Tick({
    $tmr = $this
    if (-not $tmr -and $args.Count -gt 0) { $tmr = $args[0] }
    if (-not $tmr) { $tmr = $script:BgTimer }
    $fn = if ($tmr) { $tmr.Tag } else { $null }
    if (-not $fn) { $fn = $script:fnStepBatch }
    if ($fn) { & $fn }
})

# 状态机状态
$script:BaeFiles = @(); $script:BaeTotal = 0; $script:BaeIdx = 0
$script:BaeAttempts = @(''); $script:BaeAttemptIdx = 0
$script:BaeProc = $null; $script:BaeCur = $null; $script:BaeOutDir = ''
$script:BaeDone = 0; $script:BaeSuccess = 0; $script:BaeFailed = 0
$script:BaeFailedList = [System.Collections.ArrayList]::new()
$script:BaeAbort = $false

# ---------- 依赖/配置容器 ----------
# ★ 后台任务在【独立 Runspace】中运行, 那里没有本脚本的 $script: 作用域,
#   因此把所需的一切(配置 + 函数委托 + 线程安全队列 + 停止信号)打包进 $Ctx 传入。
$script:Ctx = @{
    Config = @{
        SevenZipPath = $script:Default7zPath; Default7zPath = $script:Default7zPath
        SrcDir = ''; ExtsText = ''; PasswordText = ''
        Recurse = $false; CustomMode = $false; OutDir = ''
    }
    Fns = @{
        FindSevenZip   = (Get-Command Find-SevenZip).ScriptBlock
        ParsePasswords = (Get-Command Parse-Passwords).ScriptBlock
        ParseExts      = (Get-Command Parse-Exts).ScriptBlock
        InvokeExtract  = (Get-Command Invoke-Extract).ScriptBlock
        StartBatch     = (Get-Command Start-BatchExtract).ScriptBlock
    }
    LogQ  = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    ProgQ = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    Sync  = [hashtable]::Synchronized(@{ Stop = $false })
}

# 预填 7z 默认路径
$script:txt7zPath.Text = $script:Default7zPath
if (-not (Test-Path -LiteralPath $script:Default7zPath)) {
    # 注意: 此处在 Ctx 构建之后执行, 可安全使用委托
    $detected = & $script:fnFindSevenZip -Ctx $script:Ctx
    if ($detected) { $script:txt7zPath.Text = $detected }
}

# ---------- 事件绑定 ----------
$ui.FindName("BtnBrowse7z").Add_Click({
    $p = & $script:fnSelect7z
    if ($p) { $script:txt7zPath.Text = $p }
})

$ui.FindName("BtnBrowseSource").Add_Click({
    $p = & $script:fnSelectFolder -Initial $script:txtSourceDir.Text
    if ($p) { $script:txtSourceDir.Text = $p }
})

$ui.FindName("BtnBrowseOut").Add_Click({
    $p = & $script:fnSelectFolder -Initial $script:txtOutDir.Text
    if ($p) { $script:txtOutDir.Text = $p }
})

# 输出模式切换: 启用/禁用自定义路径输入
$script:rdoCustomDir.Add_Checked({
    $script:txtOutDir.IsEnabled   = $true
    $ui.FindName("BtnBrowseOut").IsEnabled = $true
})
$script:rdoCustomDir.Add_Unchecked({
    $script:txtOutDir.IsEnabled   = $false
    $ui.FindName("BtnBrowseOut").IsEnabled = $false
})

$ui.FindName("BtnClearLog").Add_Click({
    $script:lstLog.Items.Clear()
})

$ui.FindName("BtnStop").Add_Click({
    $script:BaeAbort = $true
    if ($script:BaeProc -and -not $script:BaeProc.HasExited) {
        try { $script:BaeProc.Kill() } catch { }
    }
    & $script:fnAddBaeLog "已请求停止, 正在结束当前任务..." 'Warning'
})

$ui.FindName("BtnStart").Add_Click({
    # —— 在 UI 线程捕获控件值 ——
    $script:Ctx.Config.SevenZipPath = $script:txt7zPath.Text.Trim()
    $script:SrcDir       = $script:txtSourceDir.Text.Trim()
    $script:PasswordText = $script:txtPasswords.Text
    $script:ExtsText     = $script:txtExts.Text
    $script:Recurse      = $script:chkRecurse.IsChecked
    $script:CustomMode   = $script:rdoCustomDir.IsChecked
    $script:OutDir       = $script:txtOutDir.Text.Trim()

    if (-not (Test-Path -LiteralPath $script:Ctx.Config.SevenZipPath)) {
        $script:Ctx.Config.SevenZipPath = & $script:fnFindSevenZip -Ctx $script:Ctx
    }
    if (-not $script:Ctx.Config.SevenZipPath) {
        & $script:fnAddBaeLog "未找到 7z.exe, 请先指定路径。" 'Error'
        return
    }

    $script:btnStart.IsEnabled = $false
    $script:btnStop.IsEnabled  = $true

    & $script:fnAddBaeLog "===== 开始批量解压任务 =====" 'Info'
    # 由 UI 线程的 DispatcherTimer 驱动状态机(见 Start-BatchExtract/Step-Batch 注释)
    & $script:fnStartBatch
})

# ========== 返回或显示 ==========
if ($Global:MainWindow) {
    & $script:fnWriteLog "ArchiveBatchExtract v1.2 已加载 (TagFix)" -Type Success
    return $ui
}
else {
    $window = New-Object System.Windows.Window
    $window.Title = '批量解压工具'
    $window.Width  = 760
    $window.Height = 720
    $window.WindowStartupLocation = "CenterScreen"
    $window.Content = $ui
    $window.Background = "#1E1E1E"
    & $script:fnWriteLog "ArchiveBatchExtract v1.0 启动成功" -Type Success
    $window.ShowDialog() | Out-Null
}
