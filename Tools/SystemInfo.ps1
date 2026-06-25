# ============================================================
#  系统信息工具
# ============================================================
Write-ToolLog "正在收集系统信息..." -Type Info

$xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    
    <StackPanel>
        <TextBlock Text="💻 系统信息" FontSize="20" FontWeight="Bold" 
                   Foreground="#333333" Margin="0,0,0,5"/>
        <TextBlock Text="当前系统硬件和操作系统详细配置" FontSize="13" 
                   Foreground="#888888" Margin="0,0,0,15"/>
    </StackPanel>
    
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <WrapPanel x:Name="InfoCards" Margin="0,5,0,0"/>
    </ScrollViewer>
</Grid>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)
$wrapPanel = $ui.FindName("InfoCards")

# ---------- 辅助函数：创建信息卡片 ----------
function New-InfoCard {
    param(
        [string]$Title,
        [string]$Icon,
        [string[]]$Lines,
        [int]$CardHeight = 180
    )
    
    $card = [System.Windows.Controls.Border]::new()
    $card.Width = 290
    $card.Height = $CardHeight
    $card.Margin = [System.Windows.Thickness]::new(5)
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FFFFFF")
    $card.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $card.Effect = [System.Windows.Media.Effects.DropShadowEffect]::new()
    $card.Effect.BlurRadius = 5
    $card.Effect.ShadowDepth = 1
    $card.Effect.Opacity = 0.1
    
    $grid = [System.Windows.Controls.Grid]::new()
    $grid.Margin = [System.Windows.Thickness]::new(15)
    
    $stack = [System.Windows.Controls.StackPanel]::new()
    
    $header = [System.Windows.Controls.StackPanel]::new()
    $header.Orientation = "Horizontal"
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    
    $iconTb = [System.Windows.Controls.TextBlock]::new()
    $iconTb.Text = $Icon
    $iconTb.FontSize = 22
    $iconTb.VerticalAlignment = "Center"
    $iconTb.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $header.AddChild($iconTb)
    
    $titleTb = [System.Windows.Controls.TextBlock]::new()
    $titleTb.Text = $Title
    $titleTb.FontSize = 15
    $titleTb.FontWeight = "SemiBold"
    $titleTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#333333")
    $titleTb.VerticalAlignment = "Center"
    $header.AddChild($titleTb)
    
    $stack.AddChild($header)
    
    foreach ($line in $Lines) {
        $tb = [System.Windows.Controls.TextBlock]::new()
        $tb.Text = $line
        $tb.FontSize = 12
        $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#555555")
        $tb.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
        $tb.TextWrapping = "Wrap"
        # 高亮标签
        if ($line -match "^(.+?):(.+)") {
            $tb.Inlines.Clear()
            $label = [System.Windows.Documents.Run]::new($Matches[1] + ": ")
            $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
            $tb.Inlines.Add($label)
            $value = [System.Windows.Documents.Run]::new($Matches[2].Trim())
            $value.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#333333")
            $value.FontWeight = "SemiBold"
            $tb.Inlines.Add($value)
        }
        $stack.AddChild($tb)
    }
    
    $grid.AddChild($stack)
    $card.AddChild($grid)
    return $card
}

# ---------- 收集系统信息 ----------
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    $memories = Get-CimInstance Win32_PhysicalMemory
    
    # 操作系统卡片
    $wrapPanel.AddChild((New-InfoCard -Title "操作系统" -Icon "🖥️" -Lines @(
        "系统: $($os.Caption)",
        "版本: $($os.Version)",
        "架构: $($os.OSArchitecture)",
        "安装日期: $(try { Get-Date $os.InstallDate -Format 'yyyy-MM-dd' } catch { '未知' })",
        "最近启动: $(try { Get-Date $os.LastBootUpTime -Format 'yyyy-MM-dd HH:mm' } catch { '未知' })",
        "时区: $([System.TimeZoneInfo]::Local.DisplayName)"
    )))
    
    # 硬件卡片
    $totalRam = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $wrapPanel.AddChild((New-InfoCard -Title "硬件信息" -Icon "🔧" -Lines @(
        "制造商: $($cs.Manufacturer)",
        "型号: $($cs.Model)",
        "处理器: $($cpu.Name.Trim())",
        "CPU核心: $($cpu.NumberOfCores) 核 / $($cpu.NumberOfLogicalProcessors) 线程",
        "内存: ${totalRam} GB",
        "显卡: $($gpu.Name)"
    )))
    
    # 内存条卡片
    $memLines = @("总数: $($memories.Count) 根内存")
    $idx = 1
    foreach ($mem in $memories) {
        $vendor = if ($mem.Manufacturer) { $mem.Manufacturer.Trim() } else { "未知厂商" }
        $cap = [math]::Round($mem.Capacity / 1GB, 1)
        $speed = if ($mem.Speed) { "$($mem.Speed) MHz" } else { "" }
        $locator = if ($mem.DeviceLocator) { $mem.DeviceLocator.Trim() } else { "Slot-$idx" }
        $partNum = if ($mem.PartNumber -and $mem.PartNumber.Trim() -ne "") { " | $($mem.PartNumber.Trim())" } else { "" }
        $memLines += "插槽$($idx) [${locator}]: ${cap} GB ${speed}${partNum}"
        $memLines += "  厂商: $vendor"
        $idx++
    }
    $memCardHeight = 120 + ($memories.Count * 28)
    $wrapPanel.AddChild((New-InfoCard -Title "内存条" -Icon "🧩" -Lines $memLines -CardHeight $memCardHeight))
    
    # BIOS
    $wrapPanel.AddChild((New-InfoCard -Title "BIOS" -Icon "⚡" -Lines @(
        "厂商: $($bios.Manufacturer)",
        "版本: $($bios.SMBIOSBIOSVersion)",
        "序列号: $($bios.SerialNumber)"
    )))
    
    # 磁盘
    foreach ($disk in $disks) {
        $free = [math]::Round($disk.FreeSpace / 1GB, 1)
        $total = [math]::Round($disk.Size / 1GB, 1)
        $used = $total - $free
        $pct = [math]::Round($used / $total * 100, 1)
        $wrapPanel.AddChild((New-InfoCard -Title "磁盘 $($disk.DeviceID)" -Icon "💾" -Lines @(
            "文件系统: $($disk.FileSystem)",
            "总容量: ${total} GB",
            "已用: ${used} GB ($pct%)",
            "可用: ${free} GB",
            "卷标: $($disk.VolumeName)"
        )))
    }
    
    # 网络
    $adapters = Get-NetAdapter -Physical | Where-Object Status -eq "Up"
    foreach ($adapter in $adapters) {
        $ip = (Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).IPAddress
        $wrapPanel.AddChild((New-InfoCard -Title "网络: $($adapter.Name)" -Icon "🌐" -Lines @(
            "状态: $($adapter.Status)",
            "速度: $(try { [math]::Round($adapter.LinkSpeed / 1000) } catch { $adapter.LinkSpeed }) Mbps",
            "MAC: $($adapter.MacAddress)",
            "IP 地址: $($ip -join ', ')"
        )))
    }
    
    Write-ToolLog "系统信息收集完成" -Type Success
}
catch {
    Write-ToolLog "收集系统信息失败: $($_.Exception.Message)" -Type Error
}

return $ui

