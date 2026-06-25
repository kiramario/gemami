# ============================================================
#  文件搜索工具 - 基于 Everything CLI (es.exe)
#  下载 es.exe: https://www.voidtools.com/ES-1.1.0.27.zip
#  解压后放到 Tools\es\ 目录或系统 PATH 中
# ============================================================
Write-ToolLog "正在加载文件搜索工具..." -Type Info

$xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 标题 -->
    <TextBlock Text="🔍 文件搜索 (Everything)" FontSize="20" FontWeight="Bold"
               Foreground="#333333" Margin="0,0,0,15"/>

    <!-- 搜索条件区域 -->
    <Border x:Name="SearchPanel" Grid.Row="1" Background="White" CornerRadius="6"
            Padding="15" Margin="0,0,0,10" Visibility="Visible">
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
                <ColumnDefinition Width="65"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <!-- 第一行: 搜索关键词 -->
            <TextBlock Text="搜索关键词:" VerticalAlignment="Center" FontSize="13"/>
            <TextBox x:Name="SearchText" Grid.Column="1" Height="28" Margin="5,0,5,8"
                     VerticalAlignment="Center"/>
            <Button x:Name="BtnSearch" Grid.Column="2" Content="🔍 搜索" Width="90"
                    Height="28" Background="#0078D4" Foreground="White" BorderThickness="0"
                    Cursor="Hand" Margin="0,0,5,8"/>

            <!-- 第二行: 过滤条件 -->
            <StackPanel Grid.Row="1" Grid.Column="1" Orientation="Horizontal">
                <TextBlock Text="路径:" VerticalAlignment="Center" FontSize="12"
                           Foreground="#666" Margin="5,0,5,0"/>
                <TextBox x:Name="PathFilter" Width="180" Height="24" VerticalAlignment="Center"
                         Margin="0,0,3,0" FontSize="12"/>
                <Button x:Name="BtnBrowsePath" Content="📂" Width="26" Height="24"
                        Background="#F0F0F0" BorderBrush="#CCCCCC" Cursor="Hand"
                        ToolTip="选择目录" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock Text="类型:" VerticalAlignment="Center" FontSize="12"
                           Foreground="#666" Margin="0,0,5,0"/>
                <ComboBox x:Name="CmbType" Width="106" Height="24" VerticalAlignment="Center"
                          Margin="0,0,10,0" FontSize="12" IsEditable="True"
                          ToolTip="选择预设或手动输入，如: *.ps1, *.txt, *.jpg"/>
            </StackPanel>
            <StackPanel Grid.Row="2" Grid.Column="1" Orientation="Horizontal">
                
                <CheckBox x:Name="ChkCase" Content="大小写" VerticalAlignment="Center"
                          FontSize="12" Margin="0,0,10,0"/>
                <CheckBox x:Name="ChkWord" Content="全词匹配" VerticalAlignment="Center"
                          FontSize="12" Margin="0,0,8,0"/>
                <CheckBox x:Name="ChkRegex" Content="正则" VerticalAlignment="Center"
                          FontSize="12" Margin="0,0,10,0"
                          ToolTip="将搜索关键词作为正则表达式，如 .+ 匹配所有文件"/>
                <TextBlock Text="最大结果:" VerticalAlignment="Center" FontSize="12"
                           Foreground="#666" Margin="0,0,5,0"/>
                <TextBox x:Name="MaxResults" Text="500" Width="50" Height="24"
                         VerticalAlignment="Center" FontSize="12" TextAlignment="Center"/>
            </StackPanel>
        </Grid>
    </Border>

    <!-- 结果列表 -->
    <Border Grid.Row="3" Background="White" CornerRadius="6" Padding="10" Margin="0,10,0,0">
        <Border.Effect>
            <DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.1"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="📋 搜索结果" FontSize="13" FontWeight="SemiBold"
                           VerticalAlignment="Center" Foreground="#333333"/>
                <TextBlock x:Name="ResultCount" Text="（就绪，请输入关键词搜索）" FontSize="12"
                           Foreground="#888888" VerticalAlignment="Center" Margin="5,0,0,0"/>
                <Button x:Name="BtnClearResults" Content="🗑 清空" Width="56" Height="22"
                        Background="#F0F0F0" Foreground="#888" BorderBrush="#CCCCCC"
                        Cursor="Hand" FontSize="11"
                        HorizontalAlignment="Right" Margin="10,0,0,0"
                        ToolTip="清除搜索结果列表"/>
            </StackPanel>
            <ListView x:Name="ResultList" Grid.Row="1" BorderThickness="0"
                      Background="#FAFAFA" SelectionMode="Extended">
                <ListView.View>
                    <GridView>
                        <GridViewColumn Header="文件名" Width="240"
                                        DisplayMemberBinding="{Binding Name}"/>
                        <GridViewColumn Header="路径" Width="320"
                                        DisplayMemberBinding="{Binding Directory}"/>
                        <GridViewColumn Header="大小" Width="80"
                                        DisplayMemberBinding="{Binding SizeDisplay}"/>
                        <GridViewColumn Header="修改日期" Width="140"
                                        DisplayMemberBinding="{Binding Date}"/>
                    </GridView>
                </ListView.View>
                <ListView.ContextMenu>
                    <ContextMenu>
                        <MenuItem Header="📂 打开文件所在位置"/>
                        <MenuItem Header="📝 复制完整路径"/>
                        <MenuItem Header="📝 复制文件名"/>
                    </ContextMenu>
                </ListView.ContextMenu>
            </ListView>
        </Grid>
    </Border>

    <!-- 底部状态栏 -->
    <Border Grid.Row="4" Margin="0,8,0,0" Padding="8,4" CornerRadius="4"
            Background="#F5F5F5">
        <StackPanel Orientation="Horizontal">
            <TextBlock x:Name="StatusEs" Text="" FontSize="11" Foreground="#888"
                       VerticalAlignment="Center"/>
            <TextBlock x:Name="StatusTime" Text="" FontSize="11" Foreground="#888"
                       VerticalAlignment="Center" Margin="20,0,0,0"/>
        </StackPanel>
    </Border>
</Grid>
'@

# 加载 XAML
$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)

# ====== script: 变量 ======
$script:EsPath = $null
$script:SearchResults = @()
$script:ui = $ui

# ====== 函数块（存入 script: 以备 WPF 回调调用）======

# 查找 es.exe
$script:FindEsExe = {
    # 1) 项目 Tools\es\ 目录
    $local = Join-Path $Global:GeminiToolsDir "lib\es\es.exe"
    Write-Host "es: $local"
    if (Test-Path $local) {
        Write-ToolLog "在项目目录找到 es.exe: $local" -Type Success
        return $local
    }
    # 2) 系统 PATH
    $fromPath = (Get-Command es.exe -ErrorAction SilentlyContinue).Source
    if ($fromPath) {
        Write-ToolLog "在 PATH 中找到 es.exe: $fromPath" -Type Success
        return $fromPath
    }
    # 3) 常见路径
    $commonPaths = @(
        "C:\Program Files\Everything\es.exe",
        "C:\Program Files (x86)\Everything\es.exe",
        "$env:LOCALAPPDATA\Everything\es.exe",
        "$env:APPDATA\Everything\es.exe"
    )
    foreach ($p in $commonPaths) {
        if (Test-Path $p) {
            Write-ToolLog "在常见路径找到 es.exe: $p" -Type Success
            return $p
        }
    }
    return $null
}

# 将简单正则转为 Everything 通配符语法
# Everything 通配符支持: * (任意字符), ? (单字符), [] (字符集)
# 不支持: . $ ^ + {n} 等正则特性
function Convert-RegexToEverythingPattern {
    param([string]$Pattern, [string]$TypeFilter)

    $result = $Pattern

    # 类型过滤转通配符: *.ext → *ext 形式追加
    if ($TypeFilter -and $TypeFilter -match '^\*\.(.+)$' -and $Matches[1] -ne '*') {
        $ext = $Matches[1]
        # 如果用户输入了 .+ 或 .* 这类正则，追加 ext 匹配
        # 如果用户输入了 *，替换为 *ext
        if ($result -eq '.' -or $result -eq '.+' -or $result -eq '.*') {
            $result = "*.$ext"
        }
        elseif ($result -eq '*') {
            $result = "*.$ext"
        }
        else {
            # 简单处理: 去除正则元字符，转为通配符
            # 移除 ^ 和 $
            $result = $result -replace '[\^$]', ''
            # \. → .
            $result = $result -replace '\\\.', '.'
            # .+ .* → *
            $result = $result -replace '\.\+|\.\*', '*'
            # 如果结果中没有 ext，追加
            if ($result -notmatch [regex]::Escape($ext)) {
                $result = "*$result*.$ext"
            }
            else {
                $result = "*$result*"
            }
        }
    }
    else {
        # 无类型过滤，简化正则
        # ^...$ → 去锚点
        $result = $result -replace '^[\^]', ''
        $result = $result -replace '[\$]$', ''
        # .+ .* → *
        $result = $result -replace '\.\+|\.\*', '*'
        # \. → .
        $result = $result -replace '\\\.', '.'
        # \d → [0-9] (Everything 通配符支持字符集)
        $result = $result -replace '\\d', '[0-9]'
        # \w → [a-zA-Z0-9_]
        $result = $result -replace '\\w', '[a-zA-Z0-9_]'
        # 如果只剩 * 或空，用 * 匹配所有
        if ([string]::IsNullOrEmpty($result) -or $result -eq '*') {
            $result = '*'
        }
    }

    return $result
}

# 确保 Everything 后台运行（绿色便携版）
$script:EnsureEverythingRunning = {
    # 1) 检查 Everything 是否已在运行
    $existing = Get-Process -Name "Everything" -ErrorAction SilentlyContinue
    if ($existing) { return $true }

    # 2) 尝试启动项目内置的 everything.exe
    $evPath = Join-Path $Global:GeminiToolsDir "lib\es\everything.exe"
    if (Test-Path $evPath) {
        Write-ToolLog "启动 Everything 后台服务..." -Type Info
        try {
            # 需要管理员权限才能读取 NTFS MFT 索引
            # 先尝试 RunAs，失败则普通启动
            try {
                Start-Process -FilePath $evPath -Verb RunAs -WindowStyle Minimized
            }
            catch {
                Start-Process -FilePath $evPath -WindowStyle Minimized
            }
            # 等待索引就绪（最多 30 秒，首次索引全盘需要时间）
            $waited = 0
            while ($waited -lt 300) {
                Start-Sleep -Milliseconds 100
                $waited++
                $count = & $script:EsPath "-get-result-count" 2>&1 | Out-String
                $count = $count.Trim()
                if ($count -match '^\d+$' -and [int]$count -gt 0) { break }
            }
            $finalCount = & $script:EsPath "-get-result-count" 2>&1 | Out-String
            Write-ToolLog "Everything 已就绪，索引文件: $($finalCount.Trim())" -Type Success
            return $true
        }
        catch {
            Write-ToolLog "启动 Everything 失败: $_" -Type Warning
            return $false
        }
    }

    # 3) 检查系统是否装了 Everything
    $sysPaths = @(
        "C:\Program Files\Everything\Everything.exe",
        "C:\Program Files (x86)\Everything\Everything.exe"
    )
    foreach ($p in $sysPaths) {
        if (Test-Path $p) {
            Write-ToolLog "启动系统 Everything..." -Type Info
            Start-Process -FilePath $p -ArgumentList "-startup" -WindowStyle Hidden
            Start-Sleep -Seconds 2
            return $true
        }
    }

    Write-ToolLog "未找到 Everything，请手动安装或放入 Tools\\lib\\es\\ 目录" -Type Warning
    return $false
}

# 执行搜索
$script:InvokeFileSearch = {
    $keyword = $script:ui.FindName("SearchText").Text.Trim()
    if ([string]::IsNullOrEmpty($keyword)) {
        $keyword = '*'
    }
    if (-not $script:EsPath -or -not (Test-Path $script:EsPath)) {
        Write-ToolLog "es.exe 未找到，无法搜索" -Type Error
        return
    }

    Write-ToolLog "正在搜索: $keyword ..." -Type Info

    # 确保 Everything 在运行
    if (-not (& $script:EnsureEverythingRunning)) {
        Write-ToolLog "Everything 未运行，无法搜索" -Type Error
        return
    }

    # 构建 es.exe 参数
    # 注意: Everything 1.4 的 -regex 与 -path 组合有 bug，因此不用 -regex，
    # 而是将正则转换为 Everything 通配符语法（Everything 通配符本身支持 * ? [] 等）
    $argsList = [System.Collections.ArrayList]::new()
    if ($script:ui.FindName("ChkCase").IsChecked) { [void]$argsList.Add("-case") }
    if ($script:ui.FindName("ChkWord").IsChecked) { [void]$argsList.Add("-wholeword") }

    $pathFilter = $script:ui.FindName("PathFilter").Text.Trim()
    if ($pathFilter) {
        [void]$argsList.Add("-path")
        [void]$argsList.Add($pathFilter)
    }

    # 类型过滤：ComboBox 可编辑，兼有预设选择和手动输入
    $typeFilter = $script:ui.FindName("CmbType").Text.Trim()
    $useRegex = $script:ui.FindName("ChkRegex").IsChecked
    if ($useRegex) {
        # 正则模式：不传 -regex（Everything 1.4 有 bug），
        # 而是将简单正则转为 Everything 通配符语法
        $keyword = Convert-RegexToEverythingPattern -Pattern $keyword -TypeFilter $typeFilter
    }
    elseif ($typeFilter) {
        # 非正则模式：通配符作为独立搜索参数传递给 es.exe
        [void]$argsList.Add($typeFilter)
    }

    $maxResults = [int]($script:ui.FindName("MaxResults").Text -as [int])
    if (-not $maxResults -or $maxResults -le 0) { $maxResults = 500 }
    [void]$argsList.Add("-n")
    [void]$argsList.Add($maxResults)
    [void]$argsList.Add($keyword)

    # 打印完整命令
    $cmdLog = "es.exe $($argsList -join ' ')"
    Write-ToolLog "执行命令: $cmdLog" -Type Info

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $ps = [System.Management.Automation.PowerShell]::Create()
        [void]$ps.AddScript({
                param($esPath, $argsList)
                & $esPath $argsList 2>&1 | Where-Object { $_ -is [string] -and $_.Trim() -ne '' }
            })
        [void]$ps.AddArgument($script:EsPath)
        [void]$ps.AddArgument($argsList)

        $handle = $ps.BeginInvoke()
        $timeout = [TimeSpan]::FromSeconds(30)
        if (-not $handle.AsyncWaitHandle.WaitOne($timeout)) {
            Write-ToolLog "搜索超时 (>30s)" -Type Warning
            $ps.Stop()
            $ps.Dispose()
            return
        }

        $rawResults = $ps.EndInvoke($handle)
        $ps.Dispose()
        $sw.Stop()

        $searchBox = $script:ui.FindName("SearchText")
        $searchBox.Text = $keyword
        $searchBox.CaretIndex = $keyword.Length

        if (-not $rawResults -or $rawResults.Count -eq 0) {
            $script:ui.FindName("ResultList").Items.Clear()
            $script:ui.FindName("ResultCount").Text = "（无结果）"
            $script:ui.FindName("StatusTime").Text = "耗时: $($sw.ElapsedMilliseconds)ms"
            Write-ToolLog "搜索完成: 无匹配结果 ($($sw.ElapsedMilliseconds)ms)" -Type Info
            return
        }

        # 构建结果列表
        $results = [System.Collections.ArrayList]::new()
        foreach ($line in $rawResults) {
            $fullPath = $line.Trim()
            if ([string]::IsNullOrEmpty($fullPath)) { continue }

            $name = Split-Path $fullPath -Leaf
            $dir = Split-Path $fullPath -Parent
            $sizeDisplay = "-"
            $date = "-"

            if (Test-Path -LiteralPath $fullPath -ErrorAction SilentlyContinue) {
                try {
                    $info = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
                    $date = $info.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                    $sizeDisplay = if ($info.Length -gt 1GB) {
                        "{0:N2} GB" -f ($info.Length / 1GB)
                    }
                    elseif ($info.Length -gt 1MB) {
                        "{0:N1} MB" -f ($info.Length / 1MB)
                    }
                    elseif ($info.Length -gt 1KB) {
                        "{0:N1} KB" -f ($info.Length / 1KB)
                    }
                    else {
                        "$($info.Length) B"
                    }
                }
                catch { }
            }

            [void]$results.Add([PSCustomObject]@{
                    Name        = $name
                    Directory   = $dir
                    FullPath    = $fullPath
                    SizeDisplay = $sizeDisplay
                    Date        = $date
                })
        }

        $script:SearchResults = $results
        $listView = $script:ui.FindName("ResultList")
        $listView.Items.Clear()
        foreach ($r in $results) {
            [void]$listView.Items.Add($r)
        }

        $elapsed = $sw.ElapsedMilliseconds
        $script:ui.FindName("ResultCount").Text = "（共 $($results.Count) 个结果）"
        $script:ui.FindName("StatusTime").Text = "耗时: ${elapsed}ms · 结果: $($results.Count)"
        Write-ToolLog "搜索完成: $($results.Count) 个结果 (${elapsed}ms)" -Type Success
    }
    catch {
        $sw.Stop()
        Write-ToolLog "搜索出错: $($_.Exception.Message)" -Type Error
    }
}

# 异步启动搜索（DispatcherTimer 延迟调度）
$script:StartSearchAsync = {
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $timer.Add_Tick({
            param($sender, $e)
            $sender.Stop()   # 使用 sender 参数获取定时器对象
            & $script:InvokeFileSearch
        })
    $timer.Start()
}

# ====== 按钮事件（WPF 回调中必须用 $script: 前缀引用函数和控件）======

$script:ui.FindName("BtnSearch").Add_Click({
        & $script:StartSearchAsync
    })

$script:ui.FindName("SearchText").Add_KeyDown({
        if ($_.Key -eq "Return") {
            & $script:StartSearchAsync
        }
    })

$script:ui.FindName("PathFilter").Add_KeyDown({
        if ($_.Key -eq "Return") {
            & $script:StartSearchAsync
        }
    })

# 清空结果
$script:ClearResults = {
    $script:ui.FindName("ResultList").Items.Clear()
    $script:SearchResults = @()
    $script:ui.FindName("ResultCount").Text = "（已清空）"
    $script:ui.FindName("StatusTime").Text = ""
    Write-ToolLog "已清空搜索结果" -Type Info
}

$script:ui.FindName("BtnClearResults").Add_Click({
        & $script:ClearResults
    })

# 路径浏览按钮
$script:ui.FindName("BtnBrowsePath").Add_Click({
        $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = "选择搜索目录"
        $dialog.SelectedPath = $script:ui.FindName("PathFilter").Text
        if ($dialog.ShowDialog() -eq "OK") {
            $script:ui.FindName("PathFilter").Text = $dialog.SelectedPath
            Write-ToolLog "已选择路径: $($dialog.SelectedPath)" -Type Info
        }
    })

# 双击结果 → 打开文件所在位置
$script:ResultListView = $script:ui.FindName("ResultList")
$script:ResultListView.Add_MouseDoubleClick({
        $sel = $script:ResultListView.SelectedItem
        if ($sel -and $sel.FullPath) {
            if (Test-Path -LiteralPath $sel.FullPath) {
                $folder = [System.IO.Path]::GetDirectoryName($sel.FullPath)
                Start-Process "explorer.exe" -ArgumentList "`"$folder`""
                Write-ToolLog "已打开: $($sel.FullPath)" -Type Info
            }
            else {
                Write-ToolLog "文件不存在: $($sel.FullPath)" -Type Warning
            }
        }
    })

# 右键菜单
$contextMenu = $script:ResultListView.ContextMenu
if ($contextMenu -and $contextMenu.Items.Count -ge 3) {
    # 右键时自动选中鼠标下的行（WPF 右键不会自动选中）
    $script:ResultListView.Add_PreviewMouseRightButtonDown({
            $hit = [System.Windows.Media.VisualTreeHelper]::HitTest($script:ResultListView, $_.GetPosition($script:ResultListView))
            if ($hit) {
                $depObj = $hit.VisualHit
                while ($depObj -ne $null -and $depObj -ne $script:ResultListView) {
                    if ($depObj -is [System.Windows.Controls.ListViewItem]) {
                        $depObj.IsSelected = $true
                        break
                    }
                    $depObj = [System.Windows.Media.VisualTreeHelper]::GetParent($depObj)
                }
            }
        })

    $contextMenu.Items[0].Add_Click({
            $sel = $script:ResultListView.SelectedItem
            write-host $sel.FullPath
            if ($sel -and $sel.FullPath -and (Test-Path -LiteralPath $sel.FullPath)) {
                $folder = [System.IO.Path]::GetDirectoryName($sel.FullPath)
                Start-Process "explorer.exe" -ArgumentList "`"$folder`""
                Write-ToolLog "已打开位置: $folder" -Type Info
            }
            else {
                Write-ToolLog "无法打开: 文件不存在或未选中" -Type Warning
            }
        })

    $contextMenu.Items[1].Add_Click({
            $sel = $script:ResultListView.SelectedItem
            if ($sel -and $sel.FullPath) {
                [System.Windows.Clipboard]::SetText($sel.FullPath)
                Write-ToolLog "已复制路径: $($sel.FullPath)" -Type Info
            }
            else {
                Write-ToolLog "未选中文件" -Type Warning
            }
        })

    $contextMenu.Items[2].Add_Click({
            $sel = $script:ResultListView.SelectedItem
            if ($sel -and $sel.Name) {
                [System.Windows.Clipboard]::SetText($sel.Name)
                Write-ToolLog "已复制文件名: $($sel.Name)" -Type Info
            }
        })
}

# ====== 初始化 ======
# 类型下拉框预设
$typePresets = @(
    "*.*（所有文件）",
    "*.ps1", "*.psm1", "*.psd1",
    "*.txt", "*.md", "*.csv", "*.json", "*.xml", "*.yaml",
    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.bmp", "*.svg",
    "*.exe", "*.dll", "*.msi",
    "*.log", "*.config", "*.ini",
    "*.zip", "*.rar", "*.7z",
    "*.mp3", "*.mp4", "*.avi", "*.mkv",
    "*.docx", "*.xlsx", "*.pptx", "*.pdf"
)
$cmb = $script:ui.FindName("CmbType")
foreach ($t in $typePresets) {
    [void]$cmb.Items.Add($t)
}
$cmb.Text = ""  # 默认不过滤类型

# es.exe 查找在主作用域执行（非回调），可直接调用 .Invoke()
$script:EsPath = & $script:FindEsExe
$searchBtn = $script:ui.FindName("BtnSearch")
$searchText = $script:ui.FindName("SearchText")

if ($script:EsPath) {
    $script:ui.FindName("StatusEs").Text = "✅ es.exe 已就绪 — $($script:EsPath)"
    Write-ToolLog "es.exe 已就绪: $($script:EsPath)" -Type Success
    $searchBtn.IsEnabled = $true
    $searchText.IsEnabled = $true
}
else {
    $script:ui.FindName("StatusEs").Text = "❌ es.exe 未找到"
    Write-ToolLog "es.exe 未找到，请下载后放到 Tools\es\ 目录" -Type Warning
    $searchBtn.IsEnabled = $false
    $searchText.IsEnabled = $false
}

Write-ToolLog "文件搜索工具就绪" -Type Success
return $ui
