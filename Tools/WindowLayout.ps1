# ============================================================
#  WindowLayout.ps1 - 窗口布局快照与恢复工具
#  功能：保存当前所有窗口位置/大小，关机后一键恢复
#  注意: 所有 WPF 控件引用必须使用 $script: 作用域
#        所有函数间调用必须使用 $script:fnXxx ScriptBlock
# ============================================================

Add-Type -AssemblyName PresentationFramework, System.Windows.Forms, System.Drawing

# ---------- Win32 API 声明 ----------
$win32Code = @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;

public class Win32Api
{
    // 窗口枚举
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();

    // 窗口信息
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    // 设置窗口
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    // 进程
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    // 显示器
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint dwFlags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMonitor, out MONITORINFOEX mi);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFOEX {
        public uint cbSize;
        public RECT rcMonitor;   // 整个显示器区域
        public RECT rcWorkArea;  // 工作区（不含任务栏）
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    public const uint MONITOR_DEFAULTTONEAREST = 0x00000002;

    // SetWindowPos 标志
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_SHOWWINDOW = 0x0040;
    public static readonly IntPtr HWND_TOP = new IntPtr(0);
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    // ShowWindow 常量
    public const int SW_RESTORE = 9;
    public const int SW_MAXIMIZE = 3;
    public const int SW_MINIMIZE = 6;
}
'@
if (-not ("Win32Api" -as [type])) {
    Add-Type -TypeDefinition $win32Code -Language CSharp
}

# ---------- 脚本级变量 ----------
$script:ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($Global:GeminiToolsDir) {
    $Global:GeminiToolsDir
}
elseif ($Global:GeminiRootDir) {
    Join-Path $Global:GeminiRootDir "Tools"
}
else {
    Split-Path $MyInvocation.MyCommand.Definition -Parent
}
$script:ConfigDir = Join-Path $script:ScriptDir "WindowLayout"
$script:SnapshotList = [System.Collections.ArrayList]::new()
$script:CurrentWindows = [System.Collections.ArrayList]::new()

# ========== XAML 界面 ==========
$xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      Background="#1E1E1E" Margin="12">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 标题 -->
    <TextBlock Grid.Row="0" Text="WindowLayout - 窗口布局快照与恢复" FontSize="18"
               FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,12"/>

    <!-- 操作按钮区 -->
    <Border Grid.Row="1" Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,8">
        <StackPanel Orientation="Horizontal">
            <Button x:Name="BtnScan" Content="扫描窗口" Width="100" Height="30"
                    Background="#0E639C" Foreground="White" BorderBrush="#0E639C" Margin="0,0,8,0"/>
            <Button x:Name="BtnSnapshot" Content="保存快照" Width="100" Height="30"
                    Background="#107C10" Foreground="White" BorderBrush="#107C10" Margin="0,0,8,0"/>
            <TextBox x:Name="TxtSnapshotName" Text="" Width="140" Height="26"
                     Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#555"
                     VerticalContentAlignment="Center" Margin="0,0,8,0"/>
            <Button x:Name="BtnRestore" Content="恢复布局" Width="100" Height="30"
                    Background="#D83B01" Foreground="White" BorderBrush="#D83B01" Margin="0,0,8,0"/>
            <CheckBox x:Name="ChkRelaunch" Content="自动启动未运行程序"
                      Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,0,0" IsChecked="True"/>
        </StackPanel>
    </Border>

    <!-- 快照列表 -->
    <Grid Grid.Row="2" Margin="0,0,0,6">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="已保存的快照:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,8,0"/>
        <ComboBox Grid.Column="1" x:Name="CmbSnapshots" Height="26"
                  Background="#2D2D2D" Foreground="#000000" BorderBrush="#555"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="8,0,0,0">
            <Button x:Name="BtnLoadSnapshot" Content="加载" Width="50" Height="24"
                    Background="#555" Foreground="White" BorderBrush="#555" Margin="0,0,4,0"/>
            <Button x:Name="BtnDeleteSnapshot" Content="删除" Width="50" Height="24"
                    Background="#555" Foreground="White" BorderBrush="#555" Margin="0,0,4,0"/>
            <Button x:Name="BtnExportImport" Content="导入/导出..." Width="80" Height="24"
                    Background="#555" Foreground="White" BorderBrush="#555"/>
        </StackPanel>
    </Grid>

    <!-- 窗口列表 -->
    <Border Grid.Row="3" Background="#1A1A1A" CornerRadius="4" Margin="0,0,0,6">
        <ListView x:Name="DgWindows" Background="#1A1A1A" Foreground="#D4D4D4"
                  BorderThickness="0" FontFamily="Consolas" FontSize="12"
                  SelectionMode="Extended">
            <ListView.View>
                <GridView AllowsColumnReorder="True">
                    <GridViewColumn Header="#" DisplayMemberBinding="{Binding Index}" Width="35"/>
                    <GridViewColumn Header="进程名" DisplayMemberBinding="{Binding ProcessName}" Width="90"/>
                    <GridViewColumn Header="窗口标题" DisplayMemberBinding="{Binding Title}" Width="200"/>
                    <GridViewColumn Header="位置" DisplayMemberBinding="{Binding Position}" Width="110"/>
                    <GridViewColumn Header="尺寸" DisplayMemberBinding="{Binding Size}" Width="80"/>
                    <GridViewColumn Header="状态" DisplayMemberBinding="{Binding State}" Width="60"/>
                    <GridViewColumn Header="显示器" DisplayMemberBinding="{Binding Monitor}" Width="65"/>
                    <GridViewColumn Header="路径" DisplayMemberBinding="{Binding ExePath}" Width="180"/>
                </GridView>
            </ListView.View>
        </ListView>
    </Border>

    <!-- 底部状态栏 -->
    <Grid Grid.Row="4" Margin="0,0,0,6">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" x:Name="TxtStatus" Foreground="#888" VerticalAlignment="Center" Text="就绪"/>
        <ProgressBar Grid.Column="1" x:Name="PgbProgress" Minimum="0" Maximum="100" Value="0" Height="6"
                     Margin="12,0" Foreground="#0E639C" Background="#2D2D2D" BorderBrush="#555"/>
        <TextBlock Grid.Column="2" x:Name="TxtCount" Foreground="#888" VerticalAlignment="Center" Text="共 0 个窗口"/>
    </Grid>

    <!-- 日志 -->
    <Border Grid.Row="5" Background="#1A1A1A" CornerRadius="4" Height="120">
        <TextBox x:Name="OutputLog" Background="#1A1A1E" Foreground="#D4D4D4"
                 BorderThickness="0" IsReadOnly="True"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 TextWrapping="Wrap" FontFamily="Consolas" FontSize="11"/>
    </Border>
</Grid>
'@

# ---------- 加载 XAML ----------
$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)

# ★ 所有 WPF 控件必须使用 $script: 作用域 ★
$script:btnScan          = $ui.FindName("BtnScan")
$script:btnSnapshot      = $ui.FindName("BtnSnapshot")
$script:btnRestore       = $ui.FindName("BtnRestore")
$script:btnLoadSnapshot  = $ui.FindName("BtnLoadSnapshot")
$script:btnDeleteSnapshot = $ui.FindName("BtnDeleteSnapshot")
$script:btnExportImport  = $ui.FindName("BtnExportImport")
$script:txtSnapshotName  = $ui.FindName("TxtSnapshotName")
$script:cmbSnapshots     = $ui.FindName("CmbSnapshots")
$script:dgWindows        = $ui.FindName("DgWindows")
$script:chkRelaunch      = $ui.FindName("ChkRelaunch")
$script:txtStatus         = $ui.FindName("TxtStatus")
$script:pgbProgress      = $ui.FindName("PgbProgress")
$script:txtCount         = $ui.FindName("TxtCount")
$script:outputLog        = $ui.FindName("OutputLog")

# ---------- 初始化 ----------
if (-not (Test-Path $script:ConfigDir)) {
    New-Item -Path $script:ConfigDir -ItemType Directory -Force | Out-Null
}

# ---------- 工具函数 ----------

function Get-AllVisibleWindows {
    # 获取所有可见非空标题窗口
    $windows = [System.Collections.Generic.List[PSObject]]::new()
    $shellWnd = [Win32Api]::GetShellWindow()

    $callback = {
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        if ($hWnd -eq [IntPtr]::Zero) { return $true }
        if (-not [Win32Api]::IsWindowVisible($hWnd)) { return $true }
        if ($hWnd -eq $shellWnd) { return $true }

        $sb = [System.Text.StringBuilder]::new(512)
        [Win32Api]::GetWindowText($hWnd, $sb, 512)
        $title = $sb.ToString().Trim()
        if ([string]::IsNullOrWhiteSpace($title) -or $title.Length -lt 2) { return $true }

        # 获取进程信息
        $pidVal = 0
        [Win32Api]::GetWindowThreadProcessId($hWnd, [ref]$pidVal) | Out-Null
        $processName = ""
        $exePath = ""
        try {
            $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
            if ($proc) {
                $processName = $proc.ProcessName
                try { $exePath = $proc.Path } catch {}
                $proc.Dispose()
            }
        } catch {}

        # 获取窗口矩形
        $rect = New-Object Win32Api+RECT
        [Win32Api]::GetWindowRect($hWnd, [ref]$rect) | Out-Null
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top

        # 判断窗口状态
        if ([Win32Api]::IsIconic($hWnd)) {
            $state = "最小化"
        }
        elseif ([Win32Api]::IsZoomed($hWnd)) {
            $state = "最大化"
        }
        else {
            $state = "正常"
        }

        # 获取显示器
        $monHwnd = [Win32Api]::MonitorFromWindow($hWnd, [Win32Api]::MONITOR_DEFAULTTONEAREST)
        $monInfo = New-Object Win32Api+MONITORINFOEX
        $monInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($monInfo)
        $monitorName = "未知"
        if ([Win32Api]::GetMonitorInfo($monHwnd, [ref]$monInfo)) {
            $monitorName = $monInfo.szDevice
        }

        $windows.Add([PSCustomObject]@{
            Handle       = $hWnd.ToInt64()
            PID          = $pidVal
            ProcessName  = $processName
            Title        = $title
            X            = $rect.Left
            Y            = $rect.Top
            Width        = $width
            Height       = $height
            State        = $state
            Monitor      = $monitorName
            ExePath      = $exePath
        }) | Out-Null

        return $true
    }

    $delegate = [Win32Api+EnumWindowsProc]$callback
    [Win32Api]::EnumWindows($delegate, [IntPtr]::Zero) | Out-Null
    return $windows
}

function Write-Log {
    param([string]$Message, [string]$Type = "Info")
    $time = Get-Date -Format "HH:mm:ss"
    $line = "[$time] $Message`r`n"

    if ($script:outputLog.Dispatcher.CheckAccess()) {
        $script:outputLog.AppendText($line)
        $script:outputLog.ScrollToEnd()
    }
    else {
        $script:outputLog.Dispatcher.Invoke([Action] {
            $script:outputLog.AppendText($line)
            $script:outputLog.ScrollToEnd()
        })
    }
    Write-Host $line.TrimEnd()
}

# ---------- 扫描窗口 ----------
function Invoke-Scan {
    & $script:fnWriteLog "正在扫描当前窗口..." -Type Info
    $script:txtStatus.Text = "扫描中..."
    $script:pgbProgress.Value = 20

    $allWins = & $script:fnGetAllWindows
    $script:CurrentWindows.Clear()

    $idx = 1
    foreach ($w in $allWins) {
        # 排除系统窗口（可选）
        $skipProcesses = @("explorer", "Taskbar", "Shell_TrayWnd", "Progman",
                           "dwm", "SearchHost", "TextInputHost", "WindowsInternal")
        if ($skipProcesses -contains $w.ProcessName.ToLower()) { continue }

        $displayObj = [PSCustomObject]@{
            Index       = $idx
            ProcessName = $w.ProcessName
            Title       = $w.Title
            Position    = "$($w.X), $($w.Y)"
            Size        = "$($w.Width)x$($w.Height)"
            State       = $w.State
            Monitor     = $w.Monitor.Replace("\\.\", "")
            ExePath     = $w.ExePath
            _Handle     = $w.Handle
            _PID        = $w.PID
            _RawX       = $w.X
            _RawY       = $w.Y
            _RawW       = $w.Width
            _RawH       = $w.Height
            _RawState   = $w.State
            _ExePath    = $w.ExePath
        }
        [void]$script:CurrentWindows.Add($displayObj)
        $idx++
    }

    $script:dgWindows.ItemsSource = $script:CurrentWindows
    $script:txtCount.Text = "共 $($script:CurrentWindows.Count) 个窗口"
    $script:pgbProgress.Value = 100
    $script:txtStatus.Text = "扫描完成"
    & $script:fnWriteLog "发现 $($script:CurrentWindows.Count) 个可管理窗口" -Type Success
}

# ---------- 保存快照 ----------
function Invoke-Snapshot {
    if ($script:CurrentWindows.Count -eq 0) {
        & $script:fnWriteLog "请先扫描窗口" -Type Warning
        return
    }

    $name = $script:txtSnapshotName.Text.Trim()
    if (-not $name) {
        $name = Get-Date -Format "yyyy-MM-dd_HHmmss"
        $script:txtSnapshotName.Text = $name
    }

    # 构建快照数据
    $snapshot = @{
        Name       = $name
        CreatedAt  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ScreenInfo = & $script:fnGetScreenInfo
        Windows    = @()
    }

    foreach ($w in $script:CurrentWindows) {
        $snapshot.Windows += @{
            ProcessName = $w.ProcessName
            Title       = $w.Title
            X           = $w._RawX
            Y           = $w._RawY
            Width       = $w._RawW
            Height      = $w._RawH
            State       = $w._RawState
            Monitor     = $w.Monitor
            ExePath     = $w._ExePath
        }
    }

    # 保存到 JSON
    $safeName = $name -replace '[\\/:*?"<>|]', '_'
    $jsonFile = Join-Path $script:ConfigDir "${safeName}.json"
    $snapshot | ConvertTo-Json -Depth 5 | Set-Content $jsonFile -Encoding UTF8

    & $script:fnWriteLog "快照已保存: ${safeName}.json ($($snapshot.Windows.Count) 个窗口)" -Type Success
    $script:txtStatus.Text = "快照已保存"

    & $script:fnRefreshSnapshots
    $script:cmbSnapshots.SelectedValue = $safeName
}

function Get-ScreenInfo {
    # 收集显示器信息用于多屏适配
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $info = @()
    foreach ($s in $screens) {
        $info += @{
            DeviceName = $s.DeviceName
            Primary    = $s.Primary
            Bounds     = "$($s.Bounds.X),$($s.Bounds.Y),$($s.Bounds.Width),$($s.Bounds.Height)"
            WorkingArea= "$($s.WorkingArea.X),$($s.WorkingArea.Y),$($s.WorkingArea.Width),$($s.WorkingArea.Height)"
        }
    }
    return $info
}

# ---------- 加载快照列表 ----------
function Refresh-Snapshots {
    $script:cmbSnapshots.Items.Clear()
    $files = Get-ChildItem -Path $script:ConfigDir -Filter "*.json" -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending
    foreach ($f in $files) {
        [void]$script:cmbSnapshots.Items.Add($f.BaseName)
    }
    if ($files.Count -gt 0) {
        & $script:fnWriteLog "找到 $($files.Count) 个已保存快照" -Type Info
    }
}

function Load-Snapshot {
    $selected = $script:cmbSnapshots.SelectedItem
    if (-not $selected) {
        & $script:fnWriteLog "请先选择一个快照" -Type Warning
        return
    }

    $jsonFile = Join-Path $script:ConfigDir "${selected}.json"
    if (-not (Test-Path $jsonFile)) {
        & $script:fnWriteLog "快照文件不存在: $selected.json" -Type Error
        return
    }

    $snap = Get-Content $jsonFile -Raw | ConvertFrom-Json
    & $script:fnWriteLog "加载快照: $($snap.Name) (创建于 $($snap.CreatedAt), $($snap.Windows.Count) 个窗口)" -Type Info

    # 显示到 DataGrid
    $script:CurrentWindows.Clear()
    $idx = 1
    foreach ($w in $snap.Windows) {
        $obj = [PSCustomObject]@{
            Index       = $idx
            ProcessName = $w.ProcessName
            Title       = $w.Title
            Position    = "$($w.X), $($w.Y)"
            Size        = "$($w.Width)x$($w.Height)"
            State       = $w.State
            Monitor     = if ($w.Monitor) { $w.Monitor } else { "-" }
            ExePath     = if ($w.ExePath) { $w.ExePath } else { "" }
            _Handle     = 0
            _PID        = 0
            _RawX       = [int]$w.X
            _RawY       = [int]$w.Y
            _RawW       = [int]$w.Width
            _RawH       = [int]$w.Height
            _RawState   = $w.State
            _ExePath    = if ($w.ExePath) { $w.ExePath } else { "" }
        }
        [void]$script:CurrentWindows.Add($obj)
        $idx++
    }
    $script:dgWindows.ItemsSource = $script:CurrentWindows
    $script:txtCount.Text = "共 $($script:CurrentWindows.Count) 个窗口"
    $script:txtStatus.Text = "已加载: $selected"
}

# ---------- 恢复布局 ----------
function Invoke-Restore {
    if ($script:CurrentWindows.Count -eq 0) {
        & $script:fnWriteLog "没有可恢复的窗口数据，请先扫描或加载快照" -Type Warning
        return
    }

    $relaunch = $script:chkRelaunch.IsChecked
    $total = $script:CurrentWindows.Count
    $success = 0
    $launched = 0
    $skipped = 0

    & $script:fnWriteLog "========== 开始恢复布局 ($total 个窗口) ==========" -Type Info
    $script:pgbProgress.Value = 10
    $script:txtStatus.Text = "正在恢复..."

    # 第一步：查找现有窗口并定位
    $currentWins = & $script:fnGetAllWindows
    $matchedHandles = @{}

    for ($i = 0; $i -lt $total; $i++) {
        $target = $script:CurrentWindows[$i]
        $percent = [math]::Round(($i + 1) / $total * 80) + 10
        $script:pgbProgress.Value = $percent
        $script:txtStatus.Text = "[$($i+1)/$total] $($target.Title)"

        # 通过进程名+标题模糊匹配找窗口
        $found = $false
        foreach ($cw in $currentWins) {
            if ($matchedHandles.ContainsKey($cw.Handle)) { continue }
            if ($cw.ProcessName -ieq $target.ProcessName -and
                $cw.Title -match ([regex]::Escape($target.Title.Substring(0, [Math]::Min(15, $target.Title.Length))))) {
                $matchedHandles[$cw.Handle] = $true
                & $script:fnRestoreWindowPos -Hwnd $cw.Handle `
                    -X $target._RawX -Y $target._RawY `
                    -W $target._RawW -H $target._RawH `
                    -State $target._RawState
                $found = $true
                $success++
                break
            }
        }

        if (-not $found) {
            # 尝试通过精确标题匹配
            foreach ($cw in $currentWins) {
                if ($matchedHandles.ContainsKey($cw.Handle)) { continue }
                if ($cw.Title -eq $target.Title) {
                    $matchedHandles[$cw.Handle] = $true
                    & $script:fnRestoreWindowPos -Hwnd $cw.Handle `
                        -X $target._RawX -Y $target._rawY `
                        -W $target._RawW -H $target._RawH `
                        -State $target._RawState
                    $found = $true
                    $success++
                    break
                }
            }
        }

        if (-not $found -and $relaunch -and $target._ExePath -and (Test-Path $target._ExePath)) {
            # 尝试启动程序
            & $script:fnWriteLog "  启动程序: $(Split-Path $target._ExePath -Leaf)" -Type Info
            try {
                Start-Process $target._ExePath
                $launched++
            }
            catch {
                & $script:fnWriteLog "  启动失败: $($_.Exception.Message)" -Type Error
            }
        }
        elseif (-not $found) {
            $skipped++
        }

        Start-Sleep -Milliseconds 150  # 给 UI 时间更新
    }

    # 如果有新启动的程序，等一下再尝试匹配
    if ($launched -gt 0) {
        & $script:fnWriteLog "等待新启动的程序初始化..." -Type Info
        Start-Sleep -Seconds 3

        # 再扫一次，尝试匹配刚启动的窗口
        $newWins = & $script:fnGetAllWindows
        for ($i = 0; $i -lt $total; $i++) {
            $target = $script:CurrentWindows[$i]
            if (-not $target._ExePath) { continue }

            foreach ($nw in $newWins) {
                if ($nw.ProcessName -ieq (Split-Path $target._ExePath -Leaf).Replace(".exe", "") -and
                    $nw.Title.Trim() -ne "") {
                    & $script:fnRestoreWindowPos -Hwnd $nw.Handle `
                        -X $target._RawX -Y $target._RawY `
                        -W $target._RawW -H $target._RawH `
                        -State $target._RawState
                    $success++
                    break
                }
            }
        }
    }

    $script:pgbProgress.Value = 100
    $script:txtStatus.Text = "恢复完成"

    $msg = "========== 恢复完毕: 定位成功 $success, 新启动 $launched, 跳过 $skipped =========="
    $type = if ($skipped -gt $success) { "Warning" } else { "Success" }
    & $script:fnWriteLog $msg -Type $type
}

function Restore-WindowPosition {
    param([long]$Hwnd, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$State)

    $hwndPtr = New-Object IntPtr($Hwnd)

    try {
        # 先恢复正常状态
        [Win32Api]::ShowWindow($hwndPtr, [Win32Api]::SW_RESTORE)

        # 设置位置和大小
        [Win32Api]::MoveWindow($hwndPtr, $X, $Y, $W, $H, $true)

        # 处理最大化/最小化
        if ($State -eq "最大化") {
            Start-Sleep -Milliseconds 50
            [Win32Api]::ShowWindow($hwndPtr, [Win32Api]::SW_MAXIMIZE)
        }
        elseif ($State -eq "最小化") {
            [Win32Api]::ShowWindow($hwndPtr, [Win32Api]::SW_MINIMIZE)
        }
    }
    catch {
        # 忽略单个窗口失败
    }
}

# ---------- 删除快照 ----------
function Delete-Snapshot {
    $selected = $script:cmbSnapshots.SelectedItem
    if (-not $selected) {
        & $script:fnWriteLog "请先选择一个快照" -Type Warning
        return
    }
    $jsonFile = Join-Path $script:ConfigDir "${selected}.json"
    if (Test-Path $jsonFile) {
        Remove-Item $jsonFile -Force
        & $script:fnWriteLog "已删除快照: $selected" -Type Info
        & $script:fnRefreshSnapshots
    }
}

# ---------- 导入/导出 ----------
function ExportImport-Snapshot {
    # 使用文件对话框选择操作
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = "导出快照为..."
    $dlg.Filter = "JSON 文件|*.json"
    $dlg.FileName = "window_layout_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    if ($dlg.ShowDialog() -eq "OK") {
        $files = Get-ChildItem $script:ConfigDir -Filter "*.json"
        $export = @{ Snapshots = @() }
        foreach ($f in $files) {
            $data = Get-Content $f.FullName -Raw | ConvertFrom-Json
            $export.Snapshots += $data
        }
        $export | ConvertTo-Json -Depth 6 | Set-Content $dlg.FileName -Encoding UTF8
        & $script:fnWriteLog "已导出全部 $($files.Count) 个快照到: $(Split-Path $dlg.FileName -Leaf)" -Type Success
    }
}

# ========== 事件绑定 ==========
try {
    $script:fnScan              = ${function:Invoke-Scan}
    $script:fnSnapshot          = ${function:Invoke-Snapshot}
    $script:fnRestore           = ${function:Invoke-Restore}
    $script:fnLoadSnapshot      = ${function:Load-Snapshot}
    $script:fnDeleteSnapshot    = ${function:Delete-Snapshot}
    $script:fnRefreshSnapshots  = ${function:Refresh-Snapshots}
    $script:fnExportImport      = ${function:ExportImport-Snapshot}
    $script:fnWriteLog          = ${function:Write-Log}
    $script:fnGetAllWindows     = ${function:Get-AllVisibleWindows}
    $script:fnRestoreWindowPos  = ${function:Restore-WindowPosition}
    $script:fnGetScreenInfo     = ${function:Get-ScreenInfo}

    $script:btnScan.Add_Click({ & $script:fnScan })
    $script:btnSnapshot.Add_Click({ & $script:fnSnapshot })
    $script:btnRestore.Add_Click({ & $script:fnRestore })
    $script:btnLoadSnapshot.Add_Click({ & $script:fnLoadSnapshot })
    $script:btnDeleteSnapshot.Add_Click({ & $script:fnDeleteSnapshot })
    $script:btnExportImport.Add_Click({ & $script:fnExportImport })

    $cmbDoubleClick = {
        if ($script:cmbSnapshots.SelectedItem) {
            & $script:fnLoadSnapshot
        }
    }
    $script:cmbSnapshots.Add_MouseDoubleClick($cmbDoubleClick)

    Write-Host "[WindowLayout] 事件绑定完成" -ForegroundColor Cyan
} catch {
    Write-Host "[WindowLayout] 事件绑定失败: $_" -ForegroundColor Red
}

# ========== 初始化 ==========
try {
    & $script:fnRefreshSnapshots
    & $script:fnWriteLog "WindowLayout v1.0 启动成功" -Type Success
    & $script:fnWriteLog "提示: 扫描窗口 -> 保存快照 -> 关机后打开 -> 加载 -> 恢复布局" -Type Info
} catch {
    Write-Host "[WindowLayout] 初始化失败: $_" -ForegroundColor Yellow
}

# ========== 启动或返回 ==========
if ($Global:MainWindow) {
    Write-Host "[WindowLayout] 嵌入模式: 返回 UI 给 MainWindow" -ForegroundColor Cyan
    return $ui
}
else {
    $window = New-Object System.Windows.Window
    $window.Title = 'WindowLayout - 窗口布局快照与恢复'
    $window.Width = 1050
    $window.Height = 700
    $window.WindowStartupLocation = "CenterScreen"
    $window.Content = $ui
    $window.Background = "#1E1E1E"
    $window.ResizeMode = "CanResizeWithGrip"
    $window.MinWidth = 900
    $window.MinHeight = 550

    $window.ShowDialog() | Out-Null
}
