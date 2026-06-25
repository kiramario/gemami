# ============================================================
#  网络检测工具
# ============================================================
Write-ToolLog "正在加载网络检测工具..." -Type Info

$xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    
    <StackPanel>
        <TextBlock Text="🌐 网络检测" FontSize="20" FontWeight="Bold" 
                   Foreground="#333333" Margin="0,0,0,5"/>
        <TextBlock Text="Ping 检测、端口扫描、DNS 查询等网络诊断工具" FontSize="13" 
                   Foreground="#888888" Margin="0,0,0,15"/>
    </StackPanel>
    
    <!-- 输入区域 -->
    <Border Grid.Row="1" Background="White" CornerRadius="6" Padding="15" Margin="0,0,0,10">
        <Border.Effect>
            <DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.1"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            
            <TextBlock Text="目标地址:" VerticalAlignment="Center" FontSize="13" Margin="0,0,10,0"/>
            <TextBox x:Name="TargetAddress" Grid.Column="1" Height="28" VerticalAlignment="Center"
                     Text="www.baidu.com" FontSize="13"/>
            
            <!-- Ping -->
            <Button x:Name="BtnPing" Grid.Column="2" Content="🔍 Ping" Width="80" Height="28"
                    Background="#0078D4" Foreground="White" BorderThickness="0" Cursor="Hand" Margin="10,0,5,0"/>
            
            <!-- 端口扫描 -->
            <Button x:Name="BtnPortScan" Grid.Column="3" Content="🔌 端口扫描" Width="90" Height="28"
                    Background="#5C2D91" Foreground="White" BorderThickness="0" Cursor="Hand" Margin="5,0,5,0"/>
            
            <!-- DNS -->
            <Button x:Name="BtnDns" Grid.Column="4" Content="📖 DNS 查询" Width="90" Height="28"
                    Background="#10893E" Foreground="White" BorderThickness="0" Cursor="Hand" Margin="5,0,0,0"/>
            
            <!-- 进度条 -->
            <ProgressBar x:Name="ProgressBar" Grid.Row="1" Grid.ColumnSpan="5" 
                         Height="4" Margin="0,10,0,5" IsIndeterminate="False" Visibility="Collapsed"/>
            
            <!-- 结果显示 -->
            <RichTextBox x:Name="ResultBox" Grid.Row="2" Grid.ColumnSpan="5" Height="350"
                         Background="#1E1E1E" Foreground="#D4D4D4" FontFamily="Consolas" FontSize="12"
                         BorderThickness="0" IsReadOnly="True" 
                         VerticalScrollBarVisibility="Auto" Margin="0,10,0,0"/>
        </Grid>
    </Border>
    
    <!-- 常用地址 -->
    <Border Grid.Row="2" Background="White" CornerRadius="6" Padding="15">
        <Border.Effect>
            <DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.1"/>
        </Border.Effect>
        <StackPanel>
            <TextBlock Text="⚡ 快速测试" FontSize="13" FontWeight="SemiBold" 
                       Foreground="#333333" Margin="0,0,0,8"/>
            <WrapPanel>
                <Button x:Name="BtnQuickBaidu" Content="百度" Width="65" Height="28"
                        Background="#F0F0F0" Foreground="#333333" BorderBrush="#CCCCCC" 
                        Cursor="Hand" Margin="0,0,8,5"/>
                <Button x:Name="BtnQuickGoogle" Content="Google DNS" Width="85" Height="28"
                        Background="#F0F0F0" Foreground="#333333" BorderBrush="#CCCCCC" 
                        Cursor="Hand" Margin="0,0,8,5"/>
                <Button x:Name="BtnQuickCloudflare" Content="Cloudflare" Width="80" Height="28"
                        Background="#F0F0F0" Foreground="#333333" BorderBrush="#CCCCCC" 
                        Cursor="Hand" Margin="0,0,8,5"/>
                <Button x:Name="BtnQuickLocal" Content="本机" Width="65" Height="28"
                        Background="#F0F0F0" Foreground="#333333" BorderBrush="#CCCCCC" 
                        Cursor="Hand" Margin="0,0,8,5"/>
                <Button x:Name="BtnQuickGithub" Content="GitHub" Width="65" Height="28"
                        Background="#F0F0F0" Foreground="#333333" BorderBrush="#CCCCCC" 
                        Cursor="Hand" Margin="0,0,8,5"/>
                <Button x:Name="BtnQuickTencent" Content="腾讯" Width="65" Height="28"
                        Background="#F0F0F0" Foreground="#333333" BorderBrush="#CCCCCC" 
                        Cursor="Hand" Margin="0,0,8,5"/>
            </WrapPanel>
        </StackPanel>
    </Border>
</Grid>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)

# ---------- 辅助：写入结果 ----------
function Append-Result {
    param(
        [System.Windows.Controls.RichTextBox]$Box,
        [string]$Text,
        [string]$Color = "#D4D4D4"
    )
    $Box.Dispatcher.Invoke([Action]{
        $p = [System.Windows.Documents.Paragraph]::new()
        $r = [System.Windows.Documents.Run]::new($Text)
        $r.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
        $p.Inlines.Add($r)
        $Box.Document.Blocks.Add($p)
        $Box.ScrollToEnd()
    })
}

# ---------- 清空结果 ----------
function Clear-Result {
    param($Box)
    $Box.Dispatcher.Invoke([Action]{ $Box.Document.Blocks.Clear() })
}

# ---------- Ping 检测 ----------
function Do-Ping {
    param($Target, $Box)
    Clear-Result -Box $Box
    Append-Result -Box $Box -Text "----------- Ping: $Target -----------" -Color "#569CD6"
    
    try {
        $results = Test-Connection -ComputerName $Target -Count 4 -BufferSize 32
        
        $times = @()
        foreach ($r in $results) {
            if ($r.StatusCode -eq 0) {
                $times += $r.ResponseTime
                Append-Result -Box $Box -Text "  来自 $($r.Address): 字节=$($r.ReplySize) 时间=$($r.ResponseTime)ms TTL=$($r.TimeToLive)" -Color "#16C60C"
            }
            else {
                Append-Result -Box $Box -Text "  ❌ 请求超时 (状态码: $($r.StatusCode))" -Color "#E81123"
            }
        }
        
        if ($times.Count -gt 0) {
            $avg = [math]::Round(($times | Measure-Object -Average).Average, 1)
            $min = ($times | Measure-Object -Minimum).Minimum
            $max = ($times | Measure-Object -Maximum).Maximum
            $loss = [math]::Round((4 - $times.Count) / 4 * 100, 0)
            
            Append-Result -Box $Box -Text "" -Color "#888888"
            Append-Result -Box $Box -Text "  ping 统计信息:" -Color "#FFFFFF"
            Append-Result -Box $Box -Text "    发送: 4, 接收: $($times.Count), 丢失: $loss%" -Color "#D4D4D4"
            Append-Result -Box $Box -Text "    最短=${min}ms, 最长=${max}ms, 平均=${avg}ms" -Color "#D4D4D4"
        }
        
        Write-ToolLog "Ping $Target 完成" -Type Success
    }
    catch {
        Append-Result -Box $Box -Text "  ❌ 错误: $($_.Exception.Message)" -Color "#E81123"
        Write-ToolLog "Ping 失败: $($_.Exception.Message)" -Type Error
    }
}

# ---------- 端口扫描 ----------
function Do-PortScan {
    param($Target, $Box)
    Clear-Result -Box $Box
    Append-Result -Box $Box -Text "----------- 端口扫描: $Target -----------" -Color "#569CD6"
    Append-Result -Box $Box -Text ""
    
    $commonPorts = @{
        21 = "FTP"
        22 = "SSH"
        23 = "Telnet"
        25 = "SMTP"
        53 = "DNS"
        80 = "HTTP"
        110 = "POP3"
        143 = "IMAP"
        443 = "HTTPS"
        993 = "IMAPS"
        995 = "POP3S"
        3306 = "MySQL"
        3389 = "RDP"
        5432 = "PostgreSQL"
        6379 = "Redis"
        8080 = "HTTP-Alt"
        8443 = "HTTPS-Alt"
        27017 = "MongoDB"
    }
    
    # 先解析域名
    try {
        $ip = [System.Net.Dns]::GetHostAddresses($Target)[0].IPAddressToString
    }
    catch {
        Append-Result -Box $Box -Text "  ❌ 无法解析地址: $Target" -Color "#E81123"
        return
    }
    
    $openCount = 0
    foreach ($port in $commonPorts.Keys | Sort-Object) {
        $client = [System.Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect($ip, $port, $null, $null)
        $wait = $async.AsyncWaitHandle.WaitOne(1000, $false)
        
        if ($wait -and $client.Connected) {
            $service = $commonPorts[$port]
            Append-Result -Box $Box -Text "  ✅ 端口 $port ($service) - 开放" -Color "#16C60C"
            $client.EndConnect($async)
            $openCount++
        }
        else {
            Append-Result -Box $Box -Text "  ⬛ 端口 $port ($($commonPorts[$port])) - 关闭" -Color "#888888"
        }
        $client.Close()
    }
    
    Append-Result -Box $Box -Text ""
    Append-Result -Box $Box -Text "  扫描完成: $openCount 个端口开放" -Color "#FFFFFF"
    Write-ToolLog "端口扫描 $Target 完成: $openCount 个开放" -Type Success
}

# ---------- DNS 查询 ----------
function Do-DnsQuery {
    param($Target, $Box)
    Clear-Result -Box $Box
    Append-Result -Box $Box -Text "----------- DNS 查询: $Target -----------" -Color "#569CD6"
    
    try {
        $hostEntry = [System.Net.Dns]::GetHostEntry($Target)
        Append-Result -Box $Box -Text ""
        Append-Result -Box $Box -Text "  主机名: $($hostEntry.HostName)" -Color "#FFFFFF"
        Append-Result -Box $Box -Text ""
        Append-Result -Box $Box -Text "  IP 地址列表:" -Color "#FFFFFF"
        
        foreach ($addr in $hostEntry.AddressList) {
            $family = if ($addr.AddressFamily -eq "InterNetwork") { "IPv4" } else { "IPv6" }
            Append-Result -Box $Box -Text "    ✅ $($addr.IPAddressToString) ($family)" -Color "#16C60C"
        }
        
        Append-Result -Box $Box -Text ""
        Append-Result -Box $Box -Text "  别名:" -Color "#FFFFFF"
        if ($hostEntry.Aliases.Count -gt 0) {
            foreach ($alias in $hostEntry.Aliases) {
                Append-Result -Box $Box -Text "    📌 $alias" -Color "#D4D4D4"
            }
        }
        else {
            Append-Result -Box $Box -Text "    （无别名）" -Color "#888888"
        }
        
        Write-ToolLog "DNS 查询 $Target 完成" -Type Success
    }
    catch {
        Append-Result -Box $Box -Text "  ❌ 查询失败: $($_.Exception.Message)" -Color "#E81123"
        Write-ToolLog "DNS 查询失败: $($_.Exception.Message)" -Type Error
    }
}

# ---------- 绑定事件 ----------
$resultBox = $ui.FindName("ResultBox")

$ui.FindName("BtnPing").Add_Click({
    $target = $ui.FindName("TargetAddress").Text
    if ($target) { Do-Ping -Target $target -Box $resultBox }
})

$ui.FindName("BtnPortScan").Add_Click({
    $target = $ui.FindName("TargetAddress").Text
    if ($target) { Do-PortScan -Target $target -Box $resultBox }
})

$ui.FindName("BtnDns").Add_Click({
    $target = $ui.FindName("TargetAddress").Text
    if ($target) { Do-DnsQuery -Target $target -Box $resultBox }
})

# 快速地址按钮
$ui.FindName("BtnQuickBaidu").Add_Click({
    $ui.FindName("TargetAddress").Text = "www.baidu.com"
    Do-Ping -Target "www.baidu.com" -Box $resultBox
})
$ui.FindName("BtnQuickGoogle").Add_Click({
    $ui.FindName("TargetAddress").Text = "8.8.8.8"
    Do-Ping -Target "8.8.8.8" -Box $resultBox
})
$ui.FindName("BtnQuickCloudflare").Add_Click({
    $ui.FindName("TargetAddress").Text = "1.1.1.1"
    Do-Ping -Target "1.1.1.1" -Box $resultBox
})
$ui.FindName("BtnQuickLocal").Add_Click({
    $ui.FindName("TargetAddress").Text = "127.0.0.1"
    Do-Ping -Target "127.0.0.1" -Box $resultBox
})
$ui.FindName("BtnQuickGithub").Add_Click({
    $ui.FindName("TargetAddress").Text = "github.com"
    Do-Ping -Target "github.com" -Box $resultBox
})
$ui.FindName("BtnQuickTencent").Add_Click({
    $ui.FindName("TargetAddress").Text = "www.qq.com"
    Do-Ping -Target "www.qq.com" -Box $resultBox
})

# 回车键触发 Ping
$ui.FindName("TargetAddress").Add_KeyDown({
    if ($_.Key -eq "Return") {
        $target = $ui.FindName("TargetAddress").Text
        if ($target) { Do-Ping -Target $target -Box $resultBox }
    }
})

Write-ToolLog "网络检测工具就绪" -Type Success
return $ui

