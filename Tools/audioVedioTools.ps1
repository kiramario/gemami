# ============================================================
#  audioVedioTools.ps1 - 音频提取 & 视频片段提取工具
#  依赖: ffmpeg.exe（lib\）、mpv.exe（lib\mpv-x86_64-v3\）
#  注意: 所有 WPF 控件引用必须使用 $script: 作用域，因为 WPF 事件回调
#        与 dot-source 加载时的局部作用域不互通。
# ============================================================

Add-Type -AssemblyName PresentationFramework, System.Windows.Forms, System.Drawing

# 尝试加载 WindowsAPICodePack（现代化文件对话框）
$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Definition -Parent }
$libDir = Join-Path $script:ScriptDir 'lib'
try { Add-Type -Path (Join-Path $libDir 'Microsoft.WindowsAPICodePack.dll') } catch { }
try { Add-Type -Path (Join-Path $libDir 'Microsoft.WindowsAPICodePack.Shell.dll') } catch { }

# ---------- 独立模式 Write-ToolLog fallback ----------
# 被 Main.ps1 dot-source 加载时,Main.ps1 已定义 Global:Write-ToolLog(写入全局 OutputLog)
# 单独跑这个脚本时,退化到写文件 _logs/audioVedioTools_yyyyMMdd.log
if (-not (Get-Command Write-ToolLog -ErrorAction SilentlyContinue)) {
    $script:SmLogBase = if ($Global:GeminiToolsDir) { $Global:GeminiToolsDir }
                        elseif ($PSScriptRoot) { $PSScriptRoot }
                        else { $PWD.Path }
    $script:SmLogDir = Join-Path $script:SmLogBase '_logs'
    if (-not (Test-Path -LiteralPath $script:SmLogDir)) {
        New-Item -Path $script:SmLogDir -ItemType Directory -Force | Out-Null
    }
    $script:SmLogFile = Join-Path $script:SmLogDir ('audioVedioTools_' + (Get-Date -Format 'yyyyMMdd') + '.log')

    function Global:Write-ToolLog {
        param([string]$Message, [string]$Type = "Info")
        $ts = (Get-Date).ToString('HH:mm:ss')
        $tag = switch ($Type) {
            'Warning' { 'WARN'  }
            'Error'   { 'ERROR' }   
            'Success' { 'OK'    }
            'Cmd'     { 'CMD'   }
            default   { 'INFO'  }
        }
        Add-Content -LiteralPath $script:SmLogFile -Value "[$ts] [$tag] $Message" -Encoding UTF8
    }
}

# ---------- 脚本级变量 ----------
$script:SelectedFile = $null
$script:OutputDir = Join-Path $env:USERPROFILE "Desktop"
$script:TimeRanges = [System.Collections.ArrayList]::new()
$script:FFmpegPath = $null
$script:FFprobePath = $null
$script:MPVPath = $null
$script:MPVProcess = $null
$script:MPVTimer = $null
$script:MPVCurrentTime = "00:00:00"
$script:MPVTimeFile = $null
$script:MPVCmdFile = $null
$script:MPVPipeName = $null
$script:MPVDuration = 0
$script:IsRunning = $false

# ---------- 查找 ffmpeg / mpv ----------
function Find-FFmpeg {
    $libDir = Join-Path $script:ScriptDir 'lib'
    # 查找 ffmpeg
    $ffmpegPath = Join-Path $libDir "ffmpeg.exe"
    if (Test-Path $ffmpegPath) { $script:FFmpegPath = $ffmpegPath }
    # 查找 ffprobe(可选, 用于精确读取时长)
    $ffprobePath = Join-Path $libDir "ffprobe.exe"
    if (Test-Path $ffprobePath) { $script:FFprobePath = $ffprobePath }
    # 查找 mpv
    $mpvDir = Join-Path $libDir "mpv-x86_64-v3"
    if (Test-Path $mpvDir) {
        $mpvPath = Join-Path $mpvDir "mpv.exe"
        if (Test-Path $mpvPath) { $script:MPVPath = $mpvPath }
    }
}

# ---------- 时间格式转换 ----------
function ConvertTo-Seconds {
    param([string]$TimeStr)
    $TimeStr = $TimeStr.Trim() -replace '：', ':'   # 兼容全角冒号
    # 简写 (纯数字无冒号): 6位=HHMMSS, 4位=MMSS, 其余回退到下方按秒(可含小数)处理
    if ($TimeStr -match '^(\d{6})$') {
        $h = [double]$TimeStr.Substring(0, 2)
        $m = [double]$TimeStr.Substring(2, 2)
        $s = [double]$TimeStr.Substring(4, 2)
        if ($m -ge 60 -or $s -ge 60) { throw "无效的时间简写: '$TimeStr'" }
        return $h * 3600 + $m * 60 + $s
    }
    if ($TimeStr -match '^(\d{4})$') {
        $m = [double]$TimeStr.Substring(0, 2)
        $s = [double]$TimeStr.Substring(2, 2)
        if ($m -ge 60 -or $s -ge 60) { throw "无效的时间简写: '$TimeStr'" }
        return $m * 60 + $s
    }
    if ($TimeStr -match '^(\d+):(\d+):(\d+(?:\.\d+)?)$') {
        return [double]$Matches[1] * 3600 + [double]$Matches[2] * 60 + [double]$Matches[3]
    }
    elseif ($TimeStr -match '^(\d+):(\d+(?:\.\d+)?)$') {
        return [double]$Matches[1] * 60 + [double]$Matches[2]
    }
    elseif ($TimeStr -match '^(\d+(?:\.\d+)?)$') {
        return [double]$Matches[1]
    }
    else {
        throw "无效的时间格式: '$TimeStr'"
    }
}

function ConvertTo-TimeString {
    param([double]$TotalSeconds)
    $h = [math]::Floor($TotalSeconds / 3600)
    $m = [math]::Floor(($TotalSeconds % 3600) / 60)
    $s = $TotalSeconds % 60
    return ("{0:D2}:{1:D2}:{2:D2}" -f [int]$h, [int]$m, [int][math]::Round($s, 2))
}

# ---------- 获取视频时长(秒) ----------
# 优先 ffprobe(JSON); 没有 ffprobe 时回退 ffmpeg -i 解析 stderr。
# 两者都用 ProcessStartInfo 读流, 避免 2>&1 在 $ErrorActionPreference='Stop' 下
# 把 stderr 变成终止性错误 (NativeCommandError)。
function Get-Duration {
    param([string]$Path)
    # ffprobe
    if ($script:FFprobePath) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:FFprobePath
            $psi.Arguments = '-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "' + $Path + '"'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $so = $p.StandardOutput.ReadToEnd()
            [void]$p.StandardError.ReadToEnd()
            $p.WaitForExit()
            $txt = $so.Trim()
            if ($p.ExitCode -eq 0 -and $txt) { return [double]$txt }
        }
        catch { }
    }
    # ffmpeg 回退
    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName = $script:FFmpegPath
    $psi2.Arguments = '-i "' + $Path + '"'
    $psi2.UseShellExecute = $false
    $psi2.RedirectStandardError = $true
    $psi2.RedirectStandardOutput = $true
    $psi2.CreateNoWindow = $true
    $p2 = [System.Diagnostics.Process]::Start($psi2)
    $out = $p2.StandardError.ReadToEnd()
    [void]$p2.StandardOutput.ReadToEnd()
    $p2.WaitForExit()
    if ($out -match 'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)') {
        return [double]$Matches[1] * 3600 + [double]$Matches[2] * 60 + [double]$Matches[3]
    }
    return 0
}

# ========== XAML 界面 ==========
$xaml = @'

<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              VerticalScrollBarVisibility="Auto"
              HorizontalScrollBarVisibility="Disabled"
              Background="#1E1E1E">
    <Grid Margin="12" Background="#1E1E1E">
    
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="🎬 音频提取 + 视频片段剪切" FontSize="18"
                FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,12"/>

        <!-- 文件选择 -->
        <Grid Grid.Row="1" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="📁 视频文件:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox Grid.Column="1" x:Name="TxtFile" IsReadOnly="True" Background="#2D2D2D" Foreground="#D4D4D4"
                    BorderBrush="#555" VerticalAlignment="Center" Height="28" Text="未选择文件"/>
            <Button Grid.Column="2" x:Name="BtnBrowseFile" Content="浏览" Width="60" Height="28"
                    Margin="6,0,0,0" Background="#0E639C" Foreground="White" BorderBrush="#0E639C"/>
            <Button Grid.Column="3" x:Name="BtnClearFile" Content="X" Width="28" Height="28"
                    Margin="4,0,0,0" Background="#555" Foreground="White" BorderBrush="#555"/>
        </Grid>

        <!-- 模式切换 -->
        <Border Grid.Row="2" Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,8">
            <StackPanel>
                <TextBlock Text="🎯 处理模式" Foreground="#CCCCCC" FontWeight="Bold" Margin="0,0,0,6"/>
                <StackPanel Orientation="Horizontal">
                    <RadioButton x:Name="RdoAudio" Content="🔊 提取音频" IsChecked="True"
                                GroupName="Mode" Foreground="#FFFFFF" Margin="0,0,20,0"/>
                    <RadioButton x:Name="RdoVideo" Content="✂️ 提取视频片段"
                                GroupName="Mode" Foreground="#FFFFFF"/>
                </StackPanel>
            </StackPanel>
        </Border>

        <!-- 音频面板 -->
        <Border Grid.Row="3" x:Name="PanelAudio" Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,8">
            <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="140"/>
                    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="音频格式:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <ComboBox Grid.Row="0" Grid.Column="1" x:Name="CmbAudioFormat" SelectedIndex="0" Height="26"
                        Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
                    <ComboBoxItem Content="MP3 (.mp3)" Foreground="#000000"/>
                    <ComboBoxItem Content="AAC (.m4a)" Foreground="#000000"/>
                    <ComboBoxItem Content="WAV (.wav)" Foreground="#000000"/>
                    <ComboBoxItem Content="FLAC (.flac)" Foreground="#000000"/>
                    <ComboBoxItem Content="OGG (.ogg)" Foreground="#000000"/>
                    <ComboBoxItem Content="原始流（复制）" Foreground="#000000"/>
                </ComboBox>
                <TextBlock Grid.Row="0" Grid.Column="2" Text="质量:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,8,0"/>
                <ComboBox Grid.Row="0" Grid.Column="3" x:Name="CmbAudioQuality" SelectedIndex="0" Height="26"
                        Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
                    <ComboBoxItem Content="最高" Foreground="#000000"/>
                    <ComboBoxItem Content="高" Foreground="#000000"/>
                    <ComboBoxItem Content="中" Foreground="#000000"/>
                    <ComboBoxItem Content="低" Foreground="#000000"/>
                </ComboBox>
                <TextBlock Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="5" x:Name="TxtAudioPreview"
                        Foreground="#888" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap"/>
            </Grid>
        </Border>

        <!-- 视频片段面板 -->
        <Border Grid.Row="4" x:Name="PanelVideo" Background="#252525" CornerRadius="6" Padding="12,18" Margin="0,0,0,8" Visibility="Collapsed">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>   <!-- 0: 时间输入 -->
                    <RowDefinition Height="Auto"/>   <!-- 1: 比例设置 -->
                    <RowDefinition Height="Auto"/>   <!-- 2: 输出格式 (新增) -->
                    <RowDefinition Height="Auto"/>   <!-- 3: 快捷添加 -->
                    <RowDefinition Height="180"/>    <!-- 4: 片段列表 -->
                    <RowDefinition Height="40"/>     <!-- 5: 删除/清空 -->
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,6">

                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="80"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="80"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="100"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <TextBlock Grid.Row="0" Grid.Column="0"
                            Text="开始:"
                            Foreground="#CCCCCC"
                            VerticalAlignment="Center"
                            Margin="0,0,4,0"/>

                    <TextBox Grid.Row="0" Grid.Column="1"
                            x:Name="TxtStartTime"
                            Text="00:00:00"
                            Height="26"
                            Background="#2D2D2D"
                            Foreground="#FFFFFF"
                            BorderBrush="#555"
                            ToolTip="时间格式: 00:07:17 或简写 000717 (6位=HHMMSS) / 0717 (4位=MMSS)，也支持全角冒号"/>

                    <TextBlock Grid.Row="0" Grid.Column="2"
                            Text="结束:"
                            Foreground="#CCCCCC"
                            VerticalAlignment="Center"
                            Margin="8,0,4,0"/>

                    <TextBox Grid.Row="0" Grid.Column="3"
                            x:Name="TxtEndTime"
                            Text="00:00:30"
                            Height="26"
                            Background="#2D2D2D"
                            Foreground="#FFFFFF"
                            BorderBrush="#555"
                            ToolTip="时间格式: 00:07:17 或简写 000717 (6位=HHMMSS) / 0717 (4位=MMSS)，也支持全角冒号"/>

                    <TextBlock Grid.Row="0" Grid.Column="4"
                            Text="输出名:"
                            Foreground="#CCCCCC"
                            VerticalAlignment="Center"
                            Margin="8,0,4,0"/>

                    <TextBox Grid.Row="0" Grid.Column="5"
                            x:Name="TxtOutputName"
                            Height="26"
                            Background="#2D2D2D"
                            Foreground="#FFFFFF"
                            BorderBrush="#555"/>

                    <Button Grid.Row="0" Grid.Column="6"
                            x:Name="BtnAddRange"
                            Content="➕ 添加片段"
                            Width="90"
                            Height="26"
                            Margin="8,0,0,0"
                            Background="#0E639C"
                            Foreground="White"
                            BorderBrush="#0E639C"/>

                </Grid>

                <!-- 比例设置 -->
                <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,6,0,6">
                    <TextBlock Text="📐 输出比例:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <ComboBox x:Name="CmbScale" SelectedIndex="0" Height="26" Width="150"
                            Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
                        <ComboBoxItem Content="原始分辨率" Foreground="#000000"/>
                        <ComboBoxItem Content="1920 (1080p 宽)" Foreground="#000000"/>
                        <ComboBoxItem Content="1280 (720p 宽)" Foreground="#000000"/>
                        <ComboBoxItem Content="854 (480p 宽)" Foreground="#000000"/>
                        <ComboBoxItem Content="640 (VGA 宽)" Foreground="#000000"/>
                        <ComboBoxItem Content="自定义宽度" Foreground="#000000"/>
                    </ComboBox>
                    <TextBox x:Name="TxtCustomWidth" Text="1280" Width="60" Height="26"
                            Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#555"
                            Margin="6,0,0,0" VerticalContentAlignment="Center"
                            IsEnabled="False"/>
                    <TextBlock x:Name="TxtScaleHint" Text="(原始, 不缩放)" Foreground="#888" FontSize="11" VerticalAlignment="Center" Margin="6,0,0,0"/>

                    <CheckBox Grid.Column="4" x:Name="ChkFastCopy" Content="快速模式（流复制, 无需重编码）"
                        IsChecked="True" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="16,0,0,0"/>
                </StackPanel>

                <!-- 输出格式 -->
                <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,6,0,6">
                    <TextBlock Text="🎞 输出格式:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <ComboBox x:Name="CmbOutputFormat" SelectedIndex="0" Height="26" Width="170"
                            Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
                        <ComboBoxItem Content="视频片段 (原格式)" Foreground="#000000"/>
                        <ComboBoxItem Content="GIF 动图" Foreground="#000000"/>
                    </ComboBox>
                    <StackPanel x:Name="PanelGif" Orientation="Horizontal" Margin="14,0,0,0" Visibility="Collapsed">
                        <TextBlock Text="尺寸:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,4,0"/>
                        <ComboBox x:Name="CmbGifPreset" SelectedIndex="1" Height="26" Width="100"
                                Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
                            <ComboBoxItem Content="小 (320×? · 8fps)" Foreground="#000000"/>
                            <ComboBoxItem Content="中 (480×? · 10fps)" Foreground="#000000"/>
                            <ComboBoxItem Content="大 (720×? · 12fps)" Foreground="#000000"/>
                        </ComboBox>
                        <TextBlock Text="宽度:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="10,0,4,0"/>
                        <TextBox x:Name="TxtGifWidth" Text="480" Width="50" Height="26"
                                Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#555" VerticalContentAlignment="Center"/>
                        <TextBlock Text="帧率:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="8,0,4,0"/>
                        <TextBox x:Name="TxtGifFps" Text="10" Width="42" Height="26"
                                Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#555" VerticalContentAlignment="Center"/>
                    </StackPanel>
                </StackPanel>

                <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,0,0,6">
                    <Button x:Name="BtnQuick1" Content="前5秒" Width="55" Height="22" Margin="0,0,6,0" Background="#3A3A3A" Foreground="#CCCCCC" BorderBrush="#555"/>
                    <Button x:Name="BtnQuick2" Content="前10秒" Width="60" Height="22" Margin="0,0,6,0" Background="#3A3A3A" Foreground="#CCCCCC" BorderBrush="#555"/>
                    <Button x:Name="BtnQuick3" Content="前30秒" Width="60" Height="22" Margin="0,0,6,0" Background="#3A3A3A" Foreground="#CCCCCC" BorderBrush="#555"/>
                    <Button x:Name="BtnQuick4" Content="中间30秒" Width="70" Height="22" Margin="0,0,6,0" Background="#3A3A3A" Foreground="#CCCCCC" BorderBrush="#555"/>
                    <Button x:Name="BtnQuick5" Content="末尾30秒" Width="70" Height="22" Background="#3A3A3A" Foreground="#CCCCCC" BorderBrush="#555"/>
                </StackPanel>

                <Border Grid.Row="4" Background="#1E1E1E" CornerRadius="4" Margin="0,0,0,6">
                    <ListBox x:Name="LstRanges" Background="#1E1E1E" Foreground="#D4D4D4" BorderThickness="0" SelectionMode="Extended" HorizontalContentAlignment="Stretch">
                        <ListBox.ItemContainerStyle>
                            <Style TargetType="ListBoxItem">
                                <Setter Property="Background" Value="Transparent"/>
                                <Setter Property="Foreground" Value="#D4D4D4"/>
                                <Setter Property="Padding" Value="8,3"/>
                            </Style>
                        </ListBox.ItemContainerStyle>
                    </ListBox>
                </Border>

                <StackPanel Grid.Row="5" Orientation="Horizontal">
                    <Button x:Name="BtnRemoveRange" Content="🗑 删除选中" Width="90" Height="24" Background="#555" Foreground="White" BorderBrush="#555" Margin="0,0,8,0"/>
                    <Button x:Name="BtnClearRanges" Content="清空列表" Width="80" Height="24" Background="#555" Foreground="White" BorderBrush="#555"/>
                    <TextBlock x:Name="TxtRangeCount" Foreground="#888" VerticalAlignment="Center" Margin="12,0,0,0" Text="共 0 个片段"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- 输出目录 -->
        <Grid Grid.Row="5" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="📂 输出目录:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox Grid.Column="1" x:Name="TxtOutputDir" Text="" Background="#2D2D2D" Foreground="#D4D4D4" BorderBrush="#555" VerticalAlignment="Center" Height="28"/>
            <Button Grid.Column="2" x:Name="BtnBrowseOutput" Content="浏览" Width="60" Height="28" Margin="6,0,0,0" Background="#0E639C" Foreground="White" BorderBrush="#0E639C"/>
        </Grid>

        <!-- mpv 预览 & 快速模式 -->
        <Grid Grid.Row="6" Margin="0,0,0,8">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button Grid.Column="0" x:Name="BtnFFplay" Content="用 mpv 预览视频" Width="160" Height="28"
                        Background="#3A3A3A" Foreground="#CCCCCC" BorderBrush="#555"/>
                <Button Grid.Column="1" x:Name="BtnSetStart" Content="设为开始" Width="70" Height="28"
                        Background="#0E639C" Foreground="White" BorderBrush="#0E639C" Margin="8,0,0,0" IsEnabled="False"/>
                <Button Grid.Column="2" x:Name="BtnSetEnd" Content="设为结束" Width="70" Height="28"
                        Background="#D83B01" Foreground="White" BorderBrush="#D83B01" Margin="4,0,0,0" IsEnabled="False"/>
                <TextBlock Grid.Column="3" x:Name="TxtFFplayTime" Foreground="#16C60C" FontSize="12"
                           VerticalAlignment="Center" Margin="12,0,0,0" Text=""/>
                <TextBlock Grid.Column="6" x:Name="TxtFFplayHint" Foreground="#888" FontSize="11" VerticalAlignment="Center" Text=""/>
            </Grid>
            <!-- mpv 进度条（拖动可跳转） -->
            <Grid Grid.Row="1" Margin="0,4,0,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" x:Name="TxtSliderMin" Text="00:00:00" Foreground="#888" FontSize="10" VerticalAlignment="Center" Width="55"/>
                <Slider Grid.Column="1" x:Name="SldProgress" Minimum="0" Maximum="100" Value="0"
                        IsEnabled="False" Margin="6,0" VerticalAlignment="Center"
                        TickFrequency="1" IsSnapToTickEnabled="True"/>
                <TextBlock Grid.Column="2" x:Name="TxtSliderMax" Text="00:00:00" Foreground="#888" FontSize="10" VerticalAlignment="Center" Width="55"/>
            </Grid>
        </Grid>

        <!-- 执行按钮 -->
        <Grid Grid.Row="7" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button Grid.Column="0" x:Name="BtnExecute" Content="▶ 开始处理" Width="110" Height="32"
                    Background="#0E639C" Foreground="White" BorderBrush="#0E639C" FontSize="14" FontWeight="Bold"/>
            <ProgressBar Grid.Column="1" x:Name="PgbProgress" Minimum="0" Maximum="100" Value="0" Height="12" Margin="12,0"
                        Foreground="#0E639C" Background="#2D2D2D" BorderBrush="#555"/>
            <TextBlock Grid.Column="2" x:Name="TxtProgress" Text="就绪" Foreground="#888" VerticalAlignment="Center"/>
        </Grid>
    </Grid>
</ScrollViewer>
'@

# ---------- 加载 XAML ----------
$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)

# ★ 所有 WPF 控件引用必须使用 $script: 作用域 ★
$script:txtFile = $ui.FindName("TxtFile")
$script:cmbAudioFormat = $ui.FindName("CmbAudioFormat")
$script:cmbAudioQuality = $ui.FindName("CmbAudioQuality")
$script:txtAudioPreview = $ui.FindName("TxtAudioPreview")
$script:panelAudio = $ui.FindName("PanelAudio")
$script:panelVideo = $ui.FindName("PanelVideo")
$script:rdoAudio = $ui.FindName("RdoAudio")
$script:rdoVideo = $ui.FindName("RdoVideo")
$script:txtStartTime = $ui.FindName("TxtStartTime")
$script:txtEndTime = $ui.FindName("TxtEndTime")
$script:txtOutputName = $ui.FindName("TxtOutputName")
$script:lstRanges = $ui.FindName("LstRanges")
$script:txtRangeCount = $ui.FindName("TxtRangeCount")
$script:txtOutputDir = $ui.FindName("TxtOutputDir")
$script:chkFastCopy = $ui.FindName("ChkFastCopy")
$script:btnExecute = $ui.FindName("BtnExecute")
$script:pgbProgress = $ui.FindName("PgbProgress")
$script:txtProgress = $ui.FindName("TxtProgress")
$script:txtFFplayHint = $ui.FindName("TxtFFplayHint")
$script:btnSetStart = $ui.FindName("BtnSetStart")
$script:btnSetEnd = $ui.FindName("BtnSetEnd")
$script:txtFFplayTime = $ui.FindName("TxtFFplayTime")
$script:sldProgress = $ui.FindName("SldProgress")
$script:txtSliderMin = $ui.FindName("TxtSliderMin")
$script:txtSliderMax = $ui.FindName("TxtSliderMax")
$script:cmbScale = $ui.FindName("CmbScale")
$script:txtCustomWidth = $ui.FindName("TxtCustomWidth")
$script:txtScaleHint = $ui.FindName("TxtScaleHint")
$script:cmbOutputFormat = $ui.FindName("CmbOutputFormat")
$script:panelGif = $ui.FindName("PanelGif")
$script:cmbGifPreset = $ui.FindName("CmbGifPreset")
$script:txtGifWidth = $ui.FindName("TxtGifWidth")
$script:txtGifFps = $ui.FindName("TxtGifFps")

# ---------- 初始化 ----------
Find-FFmpeg
$script:txtOutputDir.Text = $script:OutputDir
$script:txtFFplayHint.Text = if ($script:MPVPath) { "mpv: 已检测到" } else { "未找到 mpv.exe（lib\\mpv-x86_64-v3）" }

# ---------- 日志函数 ----------
# 委托给 Write-ToolLog: 嵌入模式(Main.ps1 加载)→ 全局 OutputLog
#                       独立模式 → _logs/audioVedioTools_yyyyMMdd.log (见顶部 fallback)
# 注意: 函数名不能用 Write-Log, 否则 dot-source 加载时会覆盖 Main.ps1 的同名全局函数,
#       导致 Write-ToolLog -> Write-Log -> Write-ToolLog 无限递归 (CallDepthOverflow)。
function Write-AvtLog {
    param([string]$Message, [string]$Type = "Info")
    Write-ToolLog $Message $Type
}

# ---------- 文件选择 ----------
function Select-VideoFile {
    try {
        $dlg = New-Object Microsoft.WindowsAPICodePack.Dialogs.CommonOpenFileDialog
        $dlg.Title = "选择视频文件"
        $dlg.InitialDirectory = [Environment]::GetFolderPath("Desktop")
        $dlg.Filters.Add("视频文件", "*.mp4;*.mkv;*.avi;*.mov;*.flv;*.wmv;*.webm;*.m4v;*.ts")
        if ($dlg.ShowDialog() -eq [Microsoft.WindowsAPICodePack.Dialogs.CommonFileDialogResult]::Ok) {
            $script:SelectedFile = $dlg.FileName
            $script:txtFile.Text = $dlg.FileName
            & $script:fnUpdatePreview
            & $script:fnWriteLog "已选择: $(Split-Path $dlg.FileName -Leaf)" -Type Info
        }
    }
    catch {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "选择视频文件"
        $dlg.Filter = "视频文件|*.mp4;*.mkv;*.avi;*.mov;*.flv;*.wmv;*.webm;*.m4v;*.ts"
        if ($dlg.ShowDialog() -eq "OK") {
            $script:SelectedFile = $dlg.FileName
            $script:txtFile.Text = $dlg.FileName
            & $script:fnUpdatePreview
            & $script:fnWriteLog "已选择: $(Split-Path $dlg.FileName -Leaf)" -Type Info
        }
    }
}

# ---------- 选择输出目录 ----------
function Select-OutputDir {
    try {
        $dlg = New-Object Microsoft.WindowsAPICodePack.Dialogs.CommonOpenFileDialog
        $dlg.Title = "选择输出目录"
        $dlg.IsFolderPicker = $true
        $dlg.InitialDirectory = $script:OutputDir
        if ($dlg.ShowDialog() -eq [Microsoft.WindowsAPICodePack.Dialogs.CommonFileDialogResult]::Ok) {
            $script:OutputDir = $dlg.FileName
            $script:txtOutputDir.Text = $dlg.FileName
        }
    }
    catch {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "选择输出目录"
        $dlg.SelectedPath = $script:OutputDir
        if ($dlg.ShowDialog() -eq "OK") {
            $script:OutputDir = $dlg.SelectedPath
            $script:txtOutputDir.Text = $dlg.SelectedPath
        }
    }
}

# ---------- 音频预览 ----------
function Update-AudioPreview {
    if (-not $script:SelectedFile) { return }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:SelectedFile)
    $formatMap = @{
        0 = @{Ext = "mp3"; Encoder = "libmp3lame"; Quality = "-q:a 0" }
        1 = @{Ext = "m4a"; Encoder = "aac"; Quality = "-b:a 320k" }
        2 = @{Ext = "wav"; Encoder = "pcm_s16le"; Quality = "" }
        3 = @{Ext = "flac"; Encoder = "flac"; Quality = "" }
        4 = @{Ext = "ogg"; Encoder = "libvorbis"; Quality = "-q:a 10" }
        5 = @{Ext = "m4a"; Encoder = "copy"; Quality = "" }
    }
    $info = $formatMap[$script:cmbAudioFormat.SelectedIndex]
    $outputPath = Join-Path $script:txtOutputDir.Text "$baseName.$($info.Ext)"
    $script:txtAudioPreview.Text = "命令预览: ffmpeg -i 输入 -vn -c:a $($info.Encoder) $($info.Quality) $outputPath".Trim()
}

# ---------- 比例设置提示 ----------
function Get-ScaleFilter {
    <#
    返回 scale filter 字符串，若为原始分辨率则返回 $null
    #>
    if ($script:chkFastCopy.IsChecked) { return $null }
    $idx = $script:cmbScale.SelectedIndex
    $presetWidths = @(0, 1920, 1280, 854, 640)
    if ($idx -le 0) { return $null }  # 原始分辨率

    if ($idx -eq 5) {
        # 自定义宽度
        $w = $script:txtCustomWidth.Text.Trim()
        if ($w -notmatch '^\d+$' -or [int]$w -le 0) { return $null }
    }
    else {
        $w = $presetWidths[$idx]
    }
    # 仅指定宽度, -2 会让高度向下取整到偶数 (libx264 要求尺寸为 2 的倍数)。
    # 不要加 force_original_aspect_ratio=decrease: 它会在只给宽度时先算出奇数高度,
    # 与 -2 的偶数取整冲突, 导致 "height not divisible by 2" 报错。
    return "scale=${w}:-2"
}

function Update-ScaleHint {
    $idx = $script:cmbScale.SelectedIndex
    $hints = @(
        "(原始, 不缩放)",
        "(宽1920, 自动匹配比例)",
        "(宽1280, 自动匹配比例)",
        "(宽854, 自动匹配比例)",
        "(宽640, 自动匹配比例)",
        "(输入目标宽度)"
    )
    $script:txtScaleHint.Text = $hints[$idx]
    $script:txtCustomWidth.IsEnabled = ($idx -eq 5)
    if ($script:chkFastCopy.IsChecked) {
        $script:txtScaleHint.Text += "  [快速模式下不缩放]"
    }
}

# ---------- 模式切换 ----------
function Switch-Mode {
    $isAudio = $script:rdoAudio.IsChecked
    $script:panelAudio.Visibility = if ($isAudio) { "Visible" } else { "Collapsed" }
    $script:panelVideo.Visibility = if ($isAudio) { "Collapsed" } else { "Visible" }
}

# ---------- 刷新列表 ----------
function Refresh-RangeList {
    $script:lstRanges.Items.Clear()
    for ($i = 0; $i -lt $script:TimeRanges.Count; $i++) {
        $range = $script:TimeRanges[$i]
        $name = if ($range.OutputName) { $range.OutputName } else { "clip_$($i+1)" }
        $item = "$($i+1). $($range.Start) -> $($range.End)   [$name]"
        $script:lstRanges.Items.Add($item)
    }
    $script:txtRangeCount.Text = "共 $($script:TimeRanges.Count) 个片段"
}

# ---------- 添加片段 ----------
function Add-Range {
    if (-not $script:SelectedFile) {
        & $script:fnWriteLog "请先选择视频文件" -Type Warning
        return
    }
    try {
        $start = & $script:fnConvertToSeconds $script:txtStartTime.Text
        $end = & $script:fnConvertToSeconds $script:txtEndTime.Text
        if ($end -le $start) {
            & $script:fnWriteLog "结束时间必须大于开始时间" -Type Warning
            return
        }
        $outName = $script:txtOutputName.Text.Trim()
        if (-not $outName) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:SelectedFile)
            $idx = $script:TimeRanges.Count + 1
            $outName = "${baseName}_clip$idx"
        }
        [void]$script:TimeRanges.Add(@{
                Start      = & $script:fnConvertToTimeString $start
                End        = & $script:fnConvertToTimeString $end
                StartSec   = $start
                EndSec     = $end
                OutputName = $outName
            })
        & $script:fnRefreshRangeList
        & $script:fnWriteLog "已添加片段: $($script:txtStartTime.Text) -> $($script:txtEndTime.Text) [$outName]" -Type Success

        # 自动将开始时间设置为上一次的结束时间，方便连续添加
        $duration = $end - $start
        $newEnd = $end + $duration
        $script:txtStartTime.Text = & $script:fnConvertToTimeString $end
        $script:txtEndTime.Text = & $script:fnConvertToTimeString $newEnd
        $script:txtOutputName.Text = ""
    }
    catch {
        & $script:fnWriteLog "添加失败: $_" -Type Error
    }
}

# ---------- 删除选中 ----------
function Remove-SelectedRanges {
    $selectedItems = @($script:lstRanges.SelectedItems)
    if ($selectedItems.Count -eq 0) { return }
    $indices = foreach ($item in $selectedItems) { $script:lstRanges.Items.IndexOf($item) }
    $indices = $indices | Sort-Object -Descending
    foreach ($i in $indices) { $script:TimeRanges.RemoveAt($i) }
    & $script:fnRefreshRangeList
    & $script:fnWriteLog "已删除 $($indices.Count) 个片段" -Type Info
}

# ---------- 清空全部 ----------
function Clear-AllRanges {
    if ($script:TimeRanges.Count -eq 0) { return }
    $script:TimeRanges.Clear()
    & $script:fnRefreshRangeList
    & $script:fnWriteLog "已清空所有片段" -Type Info
}

# ---------- 快捷添加 ----------
function QuickAdd-Range {
    param([string]$Type)
    if (-not $script:SelectedFile) {
        & $script:fnWriteLog "请先选择视频文件" -Type Warning
        return
    }
    try {
        $duration = & $script:fnGetDuration $script:SelectedFile
        if (-not $duration -or $duration -le 0) {
            & $script:fnWriteLog "无法获取视频时长" -Type Warning
            return
        }
    }
    catch {
        & $script:fnWriteLog "无法获取视频时长: $($_.Exception.Message)" -Type Warning
        return
    }

    switch ($Type) {
        "first5" { $s = 0; $e = [math]::Min(5, $duration) }
        "first10" { $s = 0; $e = [math]::Min(10, $duration) }
        "first30" { $s = 0; $e = [math]::Min(30, $duration) }
        "mid30" { $mid = $duration / 2; $s = [math]::Max(0, $mid - 15); $e = [math]::Min($duration, $mid + 15) }
        "last30" { $s = [math]::Max(0, $duration - 30); $e = $duration }
    }
    $script:txtStartTime.Text = & $script:fnConvertToTimeString $s
    $script:txtEndTime.Text = & $script:fnConvertToTimeString $e
    & $script:fnWriteLog "快捷填充: $($script:txtStartTime.Text) -> $($script:txtEndTime.Text)" -Type Info
}

# ---------- 音频提取 ----------
function Execute-AudioExtract {
    & $script:fnWriteLog "========== 开始音频提取 ==========" -Type Info
    & $script:fnWriteLog "源文件: $(Split-Path $script:SelectedFile -Leaf)" -Type Info

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($script:SelectedFile)
    $formatMap = @{
        0 = @{Ext = "mp3"; Encoder = "libmp3lame"; Quality = "-q:a 0" }
        1 = @{Ext = "m4a"; Encoder = "aac"; Quality = "-b:a 320k" }
        2 = @{Ext = "wav"; Encoder = "pcm_s16le"; Quality = "" }
        3 = @{Ext = "flac"; Encoder = "flac"; Quality = "" }
        4 = @{Ext = "ogg"; Encoder = "libvorbis"; Quality = "-q:a 10" }
        5 = @{Ext = "m4a"; Encoder = "copy"; Quality = "" }
    }
    $info = $formatMap[$script:cmbAudioFormat.SelectedIndex]
    $outputPath = Join-Path $script:txtOutputDir.Text "$baseName.$($info.Ext)"
    $finalPath = & $script:fnResolveFileConflict $outputPath
    if (-not $finalPath) { return }
    if (-not (Test-Path $script:txtOutputDir.Text)) {
        New-Item -Path $script:txtOutputDir.Text -ItemType Directory -Force | Out-Null
    }

    $ffArgs = @("-i", "`"$script:SelectedFile`"", "-vn", "-c:a", $info.Encoder)
    if ($info.Quality) { $ffArgs += $info.Quality.Split(' ') }
    $ffArgs += "`"$finalPath`""

    & $script:fnWriteLog "execute: `"$script:FFmpegPath`" $($ffArgs -join ' ')" -Type Cmd
    $script:pgbProgress.Value = 30

    try {
        $process = Start-Process -FilePath $script:FFmpegPath -ArgumentList $ffArgs -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -eq 0) {
            & $script:fnWriteLog "音频提取成功 -> $finalPath" -Type Success
            $script:pgbProgress.Value = 100
            $script:txtProgress.Text = "完成"
        }
        else {
            & $script:fnWriteLog "ffmpeg 退出码: $($process.ExitCode)" -Type Error
            $script:txtProgress.Text = "失败"
        }
    }
    catch {
        & $script:fnWriteLog "执行失败: $_" -Type Error
        $script:txtProgress.Text = "失败"
    }
}

# ---------- 视频片段提取 ----------
function Execute-VideoExtract {
    if ($script:TimeRanges.Count -eq 0) {
        & $script:fnWriteLog "没有要处理的片段" -Type Warning
        return
    }
    & $script:fnWriteLog "========== 开始提取视频片段 (共 $($script:TimeRanges.Count) 个) ==========" -Type Info
    & $script:fnWriteLog "源文件: $(Split-Path $script:SelectedFile -Leaf)" -Type Info

    if (-not (Test-Path $script:txtOutputDir.Text)) {
        New-Item -Path $script:txtOutputDir.Text -ItemType Directory -Force | Out-Null
    }

    # 在当前输出目录下创建 clip_年_月_日_时分秒 子目录
    $clipDirName = "clip_$(Get-Date -Format 'yyyy_MM_dd_HHmmss')"
    $clipDir = Join-Path $script:txtOutputDir.Text $clipDirName
    New-Item -Path $clipDir -ItemType Directory -Force | Out-Null
    & $script:fnWriteLog "输出目录: $clipDir" -Type Info

    $total = $script:TimeRanges.Count
    $success = 0
    $failed = 0

    # 输出格式: 0=视频(原格式), 1=GIF 动图
    $isGif = ($script:cmbOutputFormat.SelectedIndex -eq 1)
    if ($isGif) {
        # 解析 GIF 宽度/帧率 (非法输入回退默认)
        $gifW = 480; if ($script:txtGifWidth.Text -match '^\d+$' -and [int]$script:txtGifWidth.Text -gt 0) { $gifW = [int]$script:txtGifWidth.Text }
        $gifFps = 10; if ($script:txtGifFps.Text -match '^\d+$' -and [int]$script:txtGifFps.Text -gt 0) { $gifFps = [int]$script:txtGifFps.Text }
        if ($gifW % 2 -ne 0) { $gifW += 1 }   # 宽度取偶, 避免 GIF 尺寸异常
        & $script:fnWriteLog "输出格式: GIF (宽 $gifW, 帧率 $gifFps)" -Type Info
    }
    else {
        & $script:fnWriteLog "输出格式: 视频 (原格式)" -Type Info
    }

    for ($i = 0; $i -lt $total; $i++) {
        $range = $script:TimeRanges[$i]
        if ($isGif) {
            $ext = ".gif"
        }
        else {
            $ext = [System.IO.Path]::GetExtension($script:SelectedFile)
            if (-not $ext) { $ext = ".mp4" }
        }
        $outPath = Join-Path $clipDir "$($range.OutputName)$ext"
        $finalPath = & $script:fnResolveFileConflict $outPath
        if (-not $finalPath) { continue }

        & $script:fnWriteLog "[$($i+1)/$total] $($range.OutputName): $($range.Start) -> $($range.End)" -Type Info

        if ($isGif) {
            # GIF 动图: palettegen + paletteuse 生成高质量调色板 (单条 filtergraph)
            # fps 控制帧率, scale 控制宽度(高度自动偶数), lanczos 提升清晰度
            $gifFilter = "fps=$gifFps,scale=$gifW`:-2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
            # 输入级 seek (-ss/-to 在 -i 前) 速度更快; GIF 必然重编码
            $ffArgs = @("-ss", $range.StartSec, "-to", $range.EndSec, "-i", "`"$script:SelectedFile`"", "-vf", $gifFilter, "-loop", "0")
        }
        elseif ($script:chkFastCopy.IsChecked) {
            # 快速模式：-ss -to 在 -i 前（输入级跳转，最快，但不支持 -vf）
            # ffmpeg -ss 6163 -to 6477 -i "$path\xx.mkv" -c copy -avoid_negative_ts make_zero "$targetPth/xx.mkv"
            $ffArgs = @("-ss", $range.StartSec, "-to", $range.EndSec, "-i", "`"$script:SelectedFile`"", "-c", "copy", "-avoid_negative_ts", "make_zero")
        }
        else {
            # 重编码模式：-i 在前，-ss -to 在后（输出级 seek，确保 -vf filter 生效）
            # TODO: what different from -> ffmpeg -ss 6163 -to 6477 -i  "$path\xx.mkv" -vf "scale=720:400" -c:v libx264 -crf 23 -preset fast -c:a copy -avoid_negative_ts make_zero "$targetPth/xx.mkv"
            $ffArgs = @("-i", "`"$script:SelectedFile`"", "-ss", $range.Start, "-to", $range.End, "-c:v", "libx264", "-preset", "fast", "-crf", "23")
            $scaleFilter = & $script:fnGetScaleFilter
            if ($scaleFilter) {
                $ffArgs += @("-vf", $scaleFilter)
            }
            $ffArgs += @("-c:a", "aac", "-b:a", "192k")
        }
        $ffArgs += "`"$finalPath`""
        & $script:fnWriteLog "execute: `"$script:FFmpegPath`" $($ffArgs -join ' ')" -Type Cmd

        try {
            $process = Start-Process -FilePath $script:FFmpegPath -ArgumentList $ffArgs -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -eq 0) {
                & $script:fnWriteLog "  OK -> $(Split-Path $finalPath -Leaf)" -Type Success
                $success++
            }
            else {
                & $script:fnWriteLog "  失败, ffmpeg 退出码: $($process.ExitCode)" -Type Error
                $failed++
            }
        }
        catch {
            & $script:fnWriteLog "  执行异常: $_" -Type Error
            $failed++
        }
        $percent = [math]::Round(($i + 1) / $total * 100)
        $script:pgbProgress.Value = $percent
        $script:txtProgress.Text = "$($i+1)/$total"
    }

    $finalType = if ($failed -eq 0) { "Success" } else { "Warning" }
    & $script:fnWriteLog "========== 处理完毕: 成功 $success, 失败 $failed ==========" -Type $finalType
    $script:pgbProgress.Value = 100
    $script:txtProgress.Text = if ($failed -eq 0) { "全部完成" } else { "部分失败" }
}

# ---------- 文件名冲突处理 ----------
function Resolve-FileConflict {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $Path }
    $dir = Split-Path $Path -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    $i = 1
    while ($true) {
        $newPath = Join-Path $dir "${base}_$i$ext"
        if (-not (Test-Path $newPath)) { return $newPath }
        $i++
    }
}

# ---------- 主执行入口 ----------
function Invoke-Execute {
    if ($script:IsRunning) { return }
    if (-not $script:SelectedFile) {
        & $script:fnWriteLog "请先选择视频文件" -Type Warning
        return
    }
    if (-not $script:FFmpegPath) {
        & $script:fnWriteLog "未找到 ffmpeg.exe，请放入 lib 目录" -Type Error
        return
    }
    $script:IsRunning = $true
    $script:btnExecute.IsEnabled = $false
    $script:pgbProgress.Value = 0
    $script:txtProgress.Text = "处理中..."
    try {
        if ($script:rdoAudio.IsChecked) {
            & $script:fnExecuteAudioExtract
        }
        else {
            & $script:fnExecuteVideoExtract
        }
    }
    finally {
        $script:IsRunning = $false
        $script:btnExecute.IsEnabled = $true
    }
}

# ---------- ffplay 预览 ----------
function Invoke-FFplay {
    if (-not $script:SelectedFile) {
        & $script:fnWriteLog "请先选择视频文件" -Type Warning
        return
    }
    if (-not $script:MPVPath) {
        & $script:fnWriteLog "未找到 mpv.exe，请放入 lib\\mpv-x86_64-v3 目录" -Type Error
        return
    }

    # 关闭上一个 mpv 实例
    & $script:fnStopFFplay

    & $script:fnWriteLog "启动 mpv 播放器（支持拖动进度条）..." -Type Info
    try {
        $output = & $script:FFmpegPath -i $script:SelectedFile 2>&1 | Out-String
        $m = [regex]::Match($output, 'Duration:\s*(\d+:\d+:\d+)')
        if ($m.Success) { & $script:fnWriteLog "视频时长: $($m.Groups[1].Value)" -Type Info }
    }
    catch { }

    # 生成唯一的管道名称
    $pipeId = [System.IO.Path]::GetRandomFileName().Replace(".", "")
    $script:MPVPipeName = "mpv_pipe_$pipeId"
    $script:MPVDuration = 0

    # 通信文件
    $script:MPVTimeFile = Join-Path $env:TEMP "mpv_time_$pipeId.txt"
    $script:MPVCmdFile = Join-Path $env:TEMP "mpv_cmd_$pipeId.txt"
    "" | Set-Content $script:MPVTimeFile

    # 监控脚本：连接 mpv 命名管道，读取时间，处理 seek 命令
    $monitorScript = @'
param($pipeName, $timeFile, $cmdFile)

# 等待 mpv 创建管道（最多等 10 秒）
$retry = 0
$pipe = $null
while ($retry -lt 50) {
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName)
        $pipe.Connect(1000)
        break
    } catch {
        Start-Sleep -Milliseconds 200
        $retry++
    }
}
if (-not $pipe -or -not $pipe.IsConnected) { exit 1 }

$reader = New-Object System.IO.StreamReader($pipe)
$writer = New-Object System.IO.StreamWriter($pipe)
$writer.AutoFlush = $true

# 订阅 time-pos 和 duration 属性变化
$writer.WriteLine('{"command":["observe_property",1,"time-pos"]}')
$writer.WriteLine('{"command":["observe_property",2,"duration"]}')
$pipe.ReadTimeout = 200

$lastCmdCheck = [DateTime]::Now

while ($pipe.IsConnected) {
    # 读取 mpv 推送的 JSON 消息
    try {
        $line = $reader.ReadLine()
        if ($line) {
            $msg = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($msg.event -eq "property-change" -and $msg.name -eq "time-pos" -and $msg.data -ne $null) {
                [System.IO.File]::WriteAllText($timeFile, "$($msg.data)")
            }
            if ($msg.event -eq "property-change" -and $msg.name -eq "duration" -and $msg.data -ne $null) {
                [System.IO.File]::WriteAllText("$timeFile.dur", "$($msg.data)")
            }
        }
    } catch {
        if (-not $pipe.IsConnected) { break }
    }

    # 检查命令文件（支持 seek / fullscreen / zoom / quit）
    if (([DateTime]::Now - $lastCmdCheck).TotalMilliseconds -gt 200) {
        $lastCmdCheck = [DateTime]::Now
        if (Test-Path $cmdFile) {
            try {
                $cmd = (Get-Content $cmdFile -Raw).Trim()
                Remove-Item $cmdFile -Force
                if ($cmd -eq "FS") {
                    $writer.WriteLine('{"command":["cycle","fullscreen"]}')
                }
                elseif ($cmd -eq "ZI") {
                    $writer.WriteLine('{"command":["add","video-zoom",0.1]}')
                }
                elseif ($cmd -eq "ZO") {
                    $writer.WriteLine('{"command":["add","video-zoom",-0.1]}')
                }
                elseif ($cmd -eq "QUIT") {
                    $writer.WriteLine('{"command":["quit"]}')
                }
                elseif ($cmd -match '^[\d\.]+$') {
                    $writer.WriteLine('{"command":["set_property","time-pos",' + $cmd + ']}')
                }
            } catch {}
        }
    }
}

# 清理
try { $reader.Dispose() } catch {}
try { $writer.Dispose() } catch {}
try { $pipe.Dispose() } catch {}
if (Test-Path $timeFile) { Remove-Item $timeFile -Force }
if (Test-Path "$timeFile.dur") { Remove-Item "$timeFile.dur" -Force }
'@

    # 写入监控脚本
    $monitorFile = Join-Path $env:TEMP "mpv_monitor_$pipeId.ps1"
    [System.IO.File]::WriteAllText($monitorFile, $monitorScript, [System.Text.UTF8Encoding]::new($true))

    # 启动 mpv（独立窗口，通过命名管道通信，窗口约为屏幕 1/6）
    $mpvArgs = "--autofit=30% --input-ipc-server=\\.\pipe\$($script:MPVPipeName) --keep-open=yes `"$($script:SelectedFile)`""
    Start-Process -FilePath $script:MPVPath -ArgumentList $mpvArgs

    # 启动监控进程（隐藏窗口）
    $monitorArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$monitorFile`" -pipeName `"$($script:MPVPipeName)`" -timeFile `"$($script:MPVTimeFile)`" -cmdFile `"$($script:MPVCmdFile)`""
    $script:MPVProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $monitorArgs -PassThru

    $script:MPVCurrentTime = "00:00:00"

    # 启用按钮和进度条
    $script:btnSetStart.IsEnabled = $true
    $script:btnSetEnd.IsEnabled = $true
    $script:sldProgress.IsEnabled = $true
    $script:sldProgress.Value = 0
    $script:txtFFplayTime.Text = ""
    $script:txtSliderMin.Text = "00:00:00"
    $script:txtSliderMax.Text = "00:00:00"

    # Timer：读取时间文件 + 更新 Slider
    $script:MPVTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:MPVTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:MPVTimer.Add_Tick({
            # 读取时长
            $durFile = "$($script:MPVTimeFile).dur"
            if (Test-Path $durFile) {
                try {
                    $durRaw = Get-Content $durFile -Raw -ErrorAction SilentlyContinue
                    if ($durRaw -match '^[\d\.]+$') {
                        $script:MPVDuration = [double]$durRaw
                        $script:sldProgress.Maximum = $script:MPVDuration
                        $ts = [TimeSpan]::FromSeconds([math]::Floor($script:MPVDuration))
                        $script:txtSliderMax.Text = $ts.ToString("hh\:mm\:ss")
                    }
                }
                catch {}
            }

            # 读取当前时间
            if (Test-Path $script:MPVTimeFile) {
                try {
                    $raw = Get-Content $script:MPVTimeFile -Raw -ErrorAction SilentlyContinue
                    if ($raw -match '^[\d\.]+$') {
                        $secs = [double]$raw
                        $ts = [TimeSpan]::FromSeconds($secs)
                        $script:MPVCurrentTime = $ts.ToString("hh\:mm\:ss")
                        $script:txtFFplayTime.Text = $script:MPVCurrentTime
                        $script:sldProgress.Value = $secs
                    }
                }
                catch {}
            }
            else {
                # 时间文件被删 = mpv 已退出
                & $script:fnStopFFplay
            }
        })
    $script:MPVTimer.Start()
    & $script:fnWriteLog "mpv 已启动，拖动进度条跳转，点击「设为开始/结束」捕获时间" -Type Info
}

# Slider 拖动松手 → 发送 seek 命令
function Seek-MPV {
    param([double]$TargetSeconds)
    if ($script:MPVProcess -and -not $script:MPVProcess.HasExited -and $script:MPVCmdFile) {
        "$TargetSeconds" | Set-Content $script:MPVCmdFile
    }
}

function Stop-FFplay {
    if ($script:MPVTimer) {
        try { $script:MPVTimer.Stop() } catch { }
        $script:MPVTimer = $null
    }
    # 杀 mpv 进程（按名称查找）
    if ($script:MPVPipeName) {
        try { Get-Process -Name "mpv" -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill() } } catch { }
    }
    if ($script:MPVProcess) {
        try { if (-not $script:MPVProcess.HasExited) { $script:MPVProcess.Kill() } } catch { }
        try { $script:MPVProcess.Dispose() } catch { }
        $script:MPVProcess = $null
    }
    # 清理临时文件
    if ($script:MPVTimeFile -and (Test-Path $script:MPVTimeFile)) {
        try { Remove-Item $script:MPVTimeFile -Force } catch { }
        try { Remove-Item "$($script:MPVTimeFile).dur" -Force } catch { }
    }
    if ($script:MPVCmdFile -and (Test-Path $script:MPVCmdFile)) {
        try { Remove-Item $script:MPVCmdFile -Force } catch { }
    }
    $script:MPVTimeFile = $null
    $script:MPVCmdFile = $null
    $script:MPVPipeName = $null
    $script:MPVDuration = 0
    $script:btnSetStart.IsEnabled = $false
    $script:btnSetEnd.IsEnabled = $false
    $script:sldProgress.IsEnabled = $false
    $script:sldProgress.Value = 0
    $script:sldProgress.Maximum = 100
    $script:txtFFplayTime.Text = ""
    $script:txtSliderMin.Text = "00:00:00"
    $script:txtSliderMax.Text = "00:00:00"
    $script:MPVCurrentTime = "00:00:00"
}

function Capture-StartTime {
    if ($script:MPVCurrentTime -and $script:MPVCurrentTime -ne "00:00:00") {
        $script:txtStartTime.Text = $script:MPVCurrentTime
        & $script:fnWriteLog "开始时间已设为: $script:MPVCurrentTime" -Type Success
    }
}

function Capture-EndTime {
    if ($script:MPVCurrentTime -and $script:MPVCurrentTime -ne "00:00:00") {
        $script:txtEndTime.Text = $script:MPVCurrentTime
        & $script:fnWriteLog "结束时间已设为: $script:MPVCurrentTime" -Type Success
    }
}

# ========== 事件绑定 ==========
# WPF 回调作用域与 dot-source 作用域不互通，必须：
# 1. 函数脚本块存入 $script: 变量再调用
# 2. 控件引用都使用 $script: 前缀
$script:fnSelectVideo = (Get-Command Select-VideoFile).ScriptBlock
$script:fnSelectOutputDir = (Get-Command Select-OutputDir).ScriptBlock
$script:fnSwitchMode = (Get-Command Switch-Mode).ScriptBlock
$script:fnUpdatePreview = (Get-Command Update-AudioPreview).ScriptBlock
$script:fnAddRange = (Get-Command Add-Range).ScriptBlock
$script:fnRemoveSelectedRanges = (Get-Command Remove-SelectedRanges).ScriptBlock
$script:fnClearAllRanges = (Get-Command Clear-AllRanges).ScriptBlock
$script:fnQuickAdd = (Get-Command QuickAdd-Range).ScriptBlock
$script:fnInvokeFFplay = (Get-Command Invoke-FFplay).ScriptBlock
$script:fnStopFFplay = (Get-Command Stop-FFplay).ScriptBlock
$script:fnCaptureStartTime = (Get-Command Capture-StartTime).ScriptBlock
$script:fnCaptureEndTime = (Get-Command Capture-EndTime).ScriptBlock
$script:fnSeekMPV = (Get-Command Seek-MPV).ScriptBlock
$script:fnInvokeExecute = (Get-Command Invoke-Execute).ScriptBlock
$script:fnRefreshRangeList = (Get-Command Refresh-RangeList).ScriptBlock
$script:fnConvertToSeconds = (Get-Command ConvertTo-Seconds).ScriptBlock
$script:fnConvertToTimeString = (Get-Command ConvertTo-TimeString).ScriptBlock
$script:fnGetDuration = (Get-Command Get-Duration).ScriptBlock
$script:fnExecuteAudioExtract = (Get-Command Execute-AudioExtract).ScriptBlock
$script:fnExecuteVideoExtract = (Get-Command Execute-VideoExtract).ScriptBlock
$script:fnResolveFileConflict = (Get-Command Resolve-FileConflict).ScriptBlock
$script:fnWriteLog = (Get-Command Write-ToolLog).ScriptBlock
$script:fnGetScaleFilter = (Get-Command Get-ScaleFilter).ScriptBlock
$script:fnUpdateScaleHint = (Get-Command Update-ScaleHint).ScriptBlock

$ui.FindName("BtnBrowseFile").Add_Click({ & $script:fnSelectVideo })
$ui.FindName("BtnClearFile").Add_Click({
        $script:SelectedFile = $null
        $script:txtFile.Text = "未选择文件"
        $script:TimeRanges.Clear()
        & $script:fnRefreshRangeList
        $script:txtAudioPreview.Text = ""
        & $script:fnWriteLog "已清除文件选择" -Type Info
    })
$ui.FindName("BtnBrowseOutput").Add_Click({ & $script:fnSelectOutputDir })

$script:rdoAudio.Add_Checked({ & $script:fnSwitchMode; & $script:fnUpdatePreview })
$script:rdoVideo.Add_Checked({ & $script:fnSwitchMode })

$script:cmbAudioFormat.Add_SelectionChanged({ & $script:fnUpdatePreview })
$script:cmbAudioQuality.Add_SelectionChanged({ & $script:fnUpdatePreview })
$script:txtOutputDir.Add_TextChanged({ & $script:fnUpdatePreview })

# 比例设置事件
$script:cmbScale.Add_SelectionChanged({ & $script:fnUpdateScaleHint })
$script:txtCustomWidth.Add_TextChanged({ & $script:fnUpdateScaleHint })
$script:chkFastCopy.Add_Checked({ & $script:fnUpdateScaleHint })
$script:chkFastCopy.Add_Unchecked({ & $script:fnUpdateScaleHint })

# 输出格式切换: GIF 需重编码, 自动关闭并禁用「快速模式」
$script:cmbOutputFormat.Add_SelectionChanged({
    $isGif = ($script:cmbOutputFormat.SelectedIndex -eq 1)
    $script:panelGif.Visibility = if ($isGif) { "Visible" } else { "Collapsed" }
    if ($isGif) {
        $script:chkFastCopy.IsChecked = $false
        $script:chkFastCopy.IsEnabled = $false
        & $script:fnUpdateScaleHint
    }
    else {
        $script:chkFastCopy.IsEnabled = $true
    }
})

# GIF 尺寸预设: 0=小 1=中 2=大 (宽度/帧率). 切换时自动填充, 用户仍可手动微调。
$script:GifPresets = @(
    @{ Width = 320; Fps = 8  }   # 小
    @{ Width = 480; Fps = 10 }   # 中
    @{ Width = 720; Fps = 12 }   # 大
)
$script:cmbGifPreset.Add_SelectionChanged({
    $idx = $script:cmbGifPreset.SelectedIndex
    if ($idx -lt 0 -or $idx -gt 2) { $idx = 1 }
    $p = $script:GifPresets[$idx]
    $script:txtGifWidth.Text = $p.Width.ToString()
    $script:txtGifFps.Text   = $p.Fps.ToString()
})

$ui.FindName("BtnAddRange").Add_Click({ & $script:fnAddRange })
$ui.FindName("BtnRemoveRange").Add_Click({ & $script:fnRemoveSelectedRanges })
$ui.FindName("BtnClearRanges").Add_Click({ & $script:fnClearAllRanges })

$ui.FindName("BtnQuick1").Add_Click({ & $script:fnQuickAdd "first5" })
$ui.FindName("BtnQuick2").Add_Click({ & $script:fnQuickAdd "first10" })
$ui.FindName("BtnQuick3").Add_Click({ & $script:fnQuickAdd "first30" })
$ui.FindName("BtnQuick4").Add_Click({ & $script:fnQuickAdd "mid30" })
$ui.FindName("BtnQuick5").Add_Click({ & $script:fnQuickAdd "last30" })

$ui.FindName("BtnFFplay").Add_Click({ & $script:fnInvokeFFplay })
$script:btnSetStart.Add_Click({ & $script:fnCaptureStartTime })
$script:btnSetEnd.Add_Click({ & $script:fnCaptureEndTime })
$script:btnExecute.Add_Click({ & $script:fnInvokeExecute })

# Slider 拖动松手 → 跳转到目标位置
$script:sldProgress.Add_MouseLeftButtonUp({
        if ($script:sldProgress.IsEnabled) {
            & $script:fnSeekMPV $script:sldProgress.Value
        }
    })
$script:sldProgress.Add_PreviewMouseLeftButtonUp({
        if ($script:sldProgress.IsEnabled) {
            & $script:fnSeekMPV $script:sldProgress.Value
        }
    })

# ========== 返回或显示 ==========
if ($Global:MainWindow) {
    & $script:fnWriteLog "audioVedioTools v1.4 已加载 (ffprobe+GIF预设+时间简写)" -Type Success
    return $ui
}
else {
    $window = New-Object System.Windows.Window
    $window.Title = 'audioVedioTools'
    $window.Width = 720
    $window.Height = 980
    $window.WindowStartupLocation = "CenterScreen"
    $window.Content = $ui
    $window.Background = "#1E1E1E"

    & $script:fnWriteLog "audioVedioTools v1.0 启动成功" -Type Success
    if ($script:FFmpegPath) { & $script:fnWriteLog "ffmpeg: OK $script:FFmpegPath" -Type Success }
    else { & $script:fnWriteLog "ffmpeg: 未找到" -Type Warning }
    if ($script:MPVPath) { & $script:fnWriteLog "mpv: OK $script:MPVPath" -Type Success }
    else { & $script:fnWriteLog "mpv: 不可用（预览需要 lib\\mpv-x86_64-v3\\mpv.exe）" -Type Warning }

    $window.ShowDialog() | Out-Null
}
