# ============================================================
#  Gemini - Main.ps1
#  模块化 PowerShell GUI 工具集
#  架构: XAML(WPF) + JSON配置 + 插件式工具脚本
# ============================================================

Add-Type -AssemblyName PresentationFramework, System.Windows.Forms

# <BUILD_EMBED_RESOURCES>

# ---------- 全局变量 ----------
$script:ToolConfigs = $null
$script:CurrentToolName = $null
$script:XamlPath = Join-Path $PSScriptRoot "Main.xaml"
$script:ConfigPath = Join-Path $PSScriptRoot "Config\tools.json"
$script:ToolsDir = Join-Path $PSScriptRoot "Tools"
$script:ThemeFile = Join-Path $PSScriptRoot "Config\theme.json"
$script:CurrentTheme = "Light"  # 默认主题
$Global:MainWindow = $null
$Global:CurrentTheme = "Light"  # 供工具脚本读取
$Global:GeminiRootDir = $PSScriptRoot
$Global:GeminiToolsDir = $script:ToolsDir

# ---------- 主题配色定义 ----------
$script:Themes = @{
    "Light"    = @{
        HeaderBg = "#2D2D30"; SidebarBg = "#252526"; ContentBg = "#F0F0F0"
        CardBg = "#FFFFFF"; TextPrimary = "#333333"
        TextMuted = "#888888"; BorderColor = "#CCCCCC"
        SearchBg = "#3E3E42"; TreeParentFg = "#333333"; TreeChildFg = "#555555"
        Accent = "#0078D4"
    }
    "Dark"     = @{
        HeaderBg = "#1E1E1E"; SidebarBg = "#252526"; ContentBg = "#2D2D30"
        CardBg = "#3C3C3C"; TextPrimary = "#D4D4D4"
        TextMuted = "#888888"; BorderColor = "#555555"
        SearchBg = "#3C3C3C"; TreeParentFg = "#FFFFFF"; TreeChildFg = "#CCCCCC"
        Accent = "#0078D4"
    }
    "DeepBlue" = @{
        HeaderBg = "#1B2838"; SidebarBg = "#152232"; ContentBg = "#1E2D3D"
        CardBg = "#253545"; TextPrimary = "#D4D4D4"
        TextMuted = "#6A8AAA"; BorderColor = "#3A5568"
        SearchBg = "#253545"; TreeParentFg = "#FFFFFF"; TreeChildFg = "#AABBCC"
        Accent = "#4A90D9"
    }
    "Warm"     = @{
        HeaderBg = "#3D2E1E"; SidebarBg = "#332618"; ContentBg = "#FFF8F0"
        CardBg = "#FFFDFA"; TextPrimary = "#5C3D2E"
        TextMuted = "#A08060"; BorderColor = "#D4B896"
        SearchBg = "#4A3828"; TreeParentFg = "#FFFFFF"; TreeChildFg = "#E8D5C0"
        Accent = "#D4764E"
    }
}

# ---------- 应用主题 ----------
function Apply-Theme {
    param($ThemeName)
    $t = $script:Themes[$ThemeName]
    if (-not $t) { return }
    $script:CurrentTheme = $ThemeName
    $Global:CurrentTheme = $ThemeName
    $t2b = [System.Windows.Media.BrushConverter]::new()

    # 主区域
    $c = $Global:MainWindow
    if (-not $c) { return }
    try {
        $c.FindName("RootBorder").Background = $t2b.ConvertFromString($t.ContentBg)
        $c.FindName("HeaderBorder").Background = $t2b.ConvertFromString($t.HeaderBg)
        $c.FindName("SidebarBorder").Background = $t2b.ConvertFromString($t.SidebarBg)
        $c.FindName("SearchBorder").Background = $t2b.ConvertFromString($t.SearchBg)

        # 欢迎页
        $wt = $c.FindName("WelcomeTitle")
        if ($wt) { $wt.Foreground = $t2b.ConvertFromString($t.TextPrimary) }
        $ws = $c.FindName("WelcomeSubtitle")
        if ($ws) { $ws.Foreground = $t2b.ConvertFromString($t.TextMuted) }

        # 欢迎卡片递归染色
        Theme-WelcomeCards $c.FindName("WelcomePanel") $t

        # 左侧树节点染色
        Theme-TreeView $c.FindName("ToolTree") $t
        
        Write-Log ("主题切换: " + $ThemeName) -Type Info
    }
    catch { Write-Host "Theme err: $_" }
}

# ---------- 递归染色欢迎卡片 ----------
function Theme-WelcomeCards {
    param($parent, $t)
    if (-not $parent) { return }
    $t2b = [System.Windows.Media.BrushConverter]::new()
    if ($parent -is [System.Windows.Controls.Border] -and $parent.Tag) {
        $parent.Background = $t2b.ConvertFromString($t.CardBg)
        foreach ($child in @($parent.Child)) {
            if ($child -is [System.Windows.Controls.Panel]) {
                foreach ($tb in $child.Children) {
                    if ($tb -is [System.Windows.Controls.TextBlock]) {
                        $text = $tb.Text
                        if ($text -match '^\p{IsBasicLatin}+$') {
                            $tb.Foreground = $t2b.ConvertFromString($t.TextMuted)
                        }
                    }
                }
            }
        }
    }
    if ($parent -is [System.Windows.Controls.Panel]) {
        foreach ($child in $parent.Children) { Theme-WelcomeCards $child $t }
    }
}

# ---------- 染色树节点 ----------
function Theme-TreeView {   
    param($tree, $t)
    if (-not $tree) { return }
    $t2b = [System.Windows.Media.BrushConverter]::new()
    foreach ($parent in $tree.Items) {
        if ($parent -is [System.Windows.Controls.TreeViewItem]) {
            $parent.Foreground = $t2b.ConvertFromString($t.TreeParentFg)
            foreach ($child in $parent.Items) {
                $child.Foreground = $t2b.ConvertFromString($t.TreeChildFg)
            }
        }
    }
}

# ---------- 保存/加载主题 ----------
function Save-ThemePreference {
    try {
        $dir = Split-Path $script:ThemeFile -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        @{ theme = $script:CurrentTheme } | ConvertTo-Json | Out-File $script:ThemeFile -Encoding UTF8
    }
    catch { }
}

function Initialize-Theme {
    try {
        if (Test-Path $script:ThemeFile) {
            $saved = Get-Content $script:ThemeFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.theme -and $script:Themes.ContainsKey($saved.theme)) {
                $script:CurrentTheme = $saved.theme
            }
        }
    }
    catch { }
    # 设置 ComboBox 选中项
    $cmb = $Global:MainWindow.FindName("CmbTheme")
    if ($cmb) {
        $idx = switch ($script:CurrentTheme) {
            "Light" { 0 }
            "Dark" { 1 }
            "DeepBlue" { 2 }
            "Warm" { 3 }
            default { 0 }
        }
        $cmb.SelectedIndex = $idx
    }
    Apply-Theme $script:CurrentTheme
}

# ---------- 加载 XAML ----------
function Import-Xaml {  
    param([string]$Path)
    
    if ($script:EmbeddedXamlB64) {
        $xamlBytes = [Convert]::FromBase64String($script:EmbeddedXamlB64)
        $xamlContent = [System.Text.Encoding]::UTF8.GetString($xamlBytes)
    }
    else {
        $xamlContent = Get-Content -Path $Path -Encoding UTF8 -Raw
    }
    
    # 处理 XAML 中全局引用
    $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlContent)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    
    return $window
}

# ---------- 加载工具配置 ----------
function Import-ToolConfigs {
    if ($script:EmbeddedConfigB64) {
        $jsonBytes = [Convert]::FromBase64String($script:EmbeddedConfigB64)
        $json = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
        return $json | ConvertFrom-Json
    }

    if (-not (Test-Path $script:ConfigPath)) {
        Write-Error "配置文件不存在: $script:ConfigPath"
        return $null
    }
    $json = Get-Content -Path $script:ConfigPath -Encoding UTF8 -Raw
    return $json | ConvertFrom-Json
}

# ---------- 构建左侧导航树 ----------
function Initialize-TreeView {
    param($Window, $Configs)
    
    $tree = $Window.FindName("ToolTree")
    $tree.Items.Clear()
    
    # 按分类分组
    $groups = $Configs | Group-Object -Property "Category"
    
    foreach ($group in $groups) {
        $parentNode = [System.Windows.Controls.TreeViewItem]::new()
        $parentNode.Header = $group.Name
        $parentNode.IsExpanded = $true
        $parentNode.FontWeight = "Bold"
        $parentNode.Foreground = "#FFFFFF"
        
        foreach ($tool in $group.Group) {
            $childNode = [System.Windows.Controls.TreeViewItem]::new()
            $childNode.Header = $tool.Name
            $childNode.Tag = $tool  # 绑定完整配置数据
            $childNode.Foreground = "#CCCCCC"
            $childNode.FontSize = 13
            $childNode.Padding = [System.Windows.Thickness]::new(8, 4, 8, 4)
            
            # 图标
            if ($tool.Icon) {
                $childNode.Header = "$($tool.Icon) $($tool.Name)"
            }

            # 直接在子节点上绑定选中事件（$args[0] 即被点击的 TreeViewItem）
            $childNode.Add_Selected({
                    $sender = $args[0]
                    Write-Log ("选中: {0}" -f $sender.Header) -Type Info
                    Set-Tool -Window $Window -ToolConfig $sender.Tag
                })
            
            $parentNode.Items.Add($childNode)
        }
        $tree.Items.Add($parentNode)
    }
}

# ---------- 选择工具 ----------
function Set-Tool {
    param($Window, $ToolConfig)
    Write-Host "[Set-Tool] 选择工具: $ToolConfig" -ForegroundColor Cyan
    
    if (-not $ToolConfig -or $script:CurrentToolName -eq $ToolConfig.Name) {
        return
    }
    
    $script:CurrentToolName = $ToolConfig.Name
    $contentControl = $Window.FindName("ToolContent")
    
    # 隐藏欢迎页
    $welcomePanel = $Window.FindName("WelcomePanel")
    if ($welcomePanel) { $welcomePanel.Visibility = [System.Windows.Visibility]::Collapsed }
    
    # 加载工具脚本
    $scriptPath = Join-Path $script:ToolsDir $ToolConfig.Script

    $embeddedScript = $null
    if ($script:EmbeddedToolsB64 -and $script:EmbeddedToolsB64.ContainsKey($ToolConfig.Script)) {
        $scriptBytes = [Convert]::FromBase64String($script:EmbeddedToolsB64[$ToolConfig.Script])
        $embeddedScript = [System.Text.Encoding]::UTF8.GetString($scriptBytes).TrimStart([char]0xFEFF)
    }
    elseif (-not (Test-Path $scriptPath)) {
        Write-Log "[Set-Tool] 错误: 工具脚本不存在 - $scriptPath" -Type Error
        return
    }
    
    try {
        # 动态执行工具脚本，脚本内部通过 $Global:MainWindow 获取窗口引用
        # 脚本应返回一个 UIElement 或定义自己的 UI
        if ($embeddedScript) {
            Write-Log "[Set-Tool] embeddedScript: $embeddedScript" -Type Info
            $result = . ([ScriptBlock]::Create($embeddedScript))
        }
        else {
            Write-Log "[Set-Tool] scriptPath: $scriptPath" -Type Info
            $result = . $scriptPath
        }
        
        $uiElement = @($result) |
        Where-Object { $_ -is [System.Windows.UIElement] } |
        Select-Object -Last 1

        if ($uiElement) {
            $contentControl.Content = $uiElement
        }
        else {
            Write-Log "[Set-Tool] 工具脚本未返回可显示的 UI: $($ToolConfig.Script)" -Type Warning
        }
    }
    catch {
        Write-Log "[Set-Tool]加载工具失败: $($_.Exception.Message)" -Type Error
    }
}

# ---------- 输出日志 ----------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success", "Cmd")]
        [string]$Type = "Info"
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $tag = switch ($Type) {
        "Info" { "INFO" }
        "Warning" { "WARN" }
        "Error" { "ERROR" }
        "Success" { "OK" }
        "Cmd" { "CMD" }
    }

    $line = "[$timestamp] [$tag] $Message"

    # 写入 _logs/Main_yyyyMMdd.log (按天分文件,追加模式)
    if (-not $script:MainLogFile) {
        $script:MainLogDir = Join-Path $Global:GeminiRootDir '_logs'
        if (-not (Test-Path -LiteralPath $script:MainLogDir)) {
            New-Item -Path $script:MainLogDir -ItemType Directory -Force | Out-Null
        }
        $script:MainLogFile = Join-Path $script:MainLogDir ('Main_' + (Get-Date -Format 'yyyyMMdd') + '.log')
    }
    Add-Content -LiteralPath $script:MainLogFile -Value $line -Encoding UTF8

    # 同时输出到控制台(开发/调试用)
    Write-Host $line
}

# ---------- 全局日志函数（供工具脚本调用） ----------
function Global:Write-ToolLog {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
    Write-Log -Message $Message -Type $Type
}

# ---------- 搜索过滤 ----------
function Find-Tools {
    param($Window, [string]$Keyword)
    
    $tree = $Window.FindName("ToolTree")
    
    foreach ($parent in $tree.Items) {
        $hasVisible = $false
        foreach ($child in $parent.Items) {
            $name = $child.Header.ToString()
            $match = [string]::IsNullOrEmpty($Keyword) -or $name.Contains($Keyword)
            $child.Visibility = if ($match) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
            if ($match) { $hasVisible = $true }
        }
        $parent.Visibility = if ($hasVisible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
}

# ---------- 初始化显示 ----------
function Initialize-Content {
    param($Window)
    
    # 隐藏欢迎页
    $welcomePanel = $Window.FindName("WelcomePanel")
    if ($welcomePanel) { $welcomePanel.Visibility = [System.Windows.Visibility]::Collapsed }
    $contentControl = $Window.FindName("ToolContent")

    $scriptPath = Join-Path $script:ToolsDir "_diag_v2.ps1" # 测试使用
    $result = . $scriptPath
    
    $contentControl.Content = $result
}

# ---------- 事件绑定 ----------
function Register-Events {
    param($Window)
    
    # 标题栏拖拽
    $Window.Add_MouseLeftButtonDown({
            if ($_.OriginalSource -isnot [System.Windows.Controls.Button] -and
                $_.OriginalSource -isnot [System.Windows.Controls.TextBox]) {
                $Global:MainWindow.DragMove()
            }
        })
    
    # TreeView 选择事件（已在 Initialize-TreeView 中为每个节点单独绑定）
    
    # 关闭按钮
    $btnClose = $Window.FindName("BtnClose")
    $btnClose.Add_Click({ $Global:MainWindow.Close() })
    
    # ---- 窗口缩放与全屏 ----
    $script:WindowScale = 1.0
    $script:IsFullscreen = $false
    $script:LastRect = @{ Left = 0; Top = 0; Width = 1000; Height = 700 }
    
    # 放大窗口 (+10%)
    $btnZoomIn = $Window.FindName("BtnZoomIn")
    $btnZoomIn.Add_Click({
            if ($script:IsFullscreen) { return }
            $script:WindowScale = [Math]::Min(2.0, $script:WindowScale + 0.1)
            $factor = 1.0 / 0.9  # 约 +11%
            $Global:MainWindow.Width = [Math]::Min(2560, $Global:MainWindow.Width * $factor)
            $Global:MainWindow.Height = [Math]::Min(1440, $Global:MainWindow.Height * $factor)
        })
    
    # 缩小窗口 (-10%)
    $btnZoomOut = $Window.FindName("BtnZoomOut")
    $btnZoomOut.Add_Click({
            if ($script:IsFullscreen) { return }
            $script:WindowScale = [Math]::Max(0.5, $script:WindowScale - 0.1)
            $factor = 0.9  # 约 -10%
            $Global:MainWindow.Width = [Math]::Max(600, $Global:MainWindow.Width * $factor)
            $Global:MainWindow.Height = [Math]::Max(400, $Global:MainWindow.Height * $factor)
        })
    
    # 全屏切换
    $btnFullscreen = $Window.FindName("BtnFullscreen")
    $btnFullscreen.Add_Click({
            if ($script:IsFullscreen) {
                # 退出全屏
                $Global:MainWindow.WindowState = "Normal"
                $Global:MainWindow.Topmost = $false
                $Global:MainWindow.Left = $script:LastRect.Left
                $Global:MainWindow.Top = $script:LastRect.Top
                $Global:MainWindow.Width = $script:LastRect.Width
                $Global:MainWindow.Height = $script:LastRect.Height
                $btnFullscreen.Content = "⛶"
                $script:IsFullscreen = $false
            }
            else {
                # 进入全屏
                $script:LastRect.Left = $Global:MainWindow.Left
                $script:LastRect.Top = $Global:MainWindow.Top
                $script:LastRect.Width = $Global:MainWindow.Width
                $script:LastRect.Height = $Global:MainWindow.Height
                $Global:MainWindow.WindowState = "Maximized"
                $Global:MainWindow.Topmost = $true
                $btnFullscreen.Content = "⛷"
                $script:IsFullscreen = $true
            }
        })
    
    # ESC 退出全屏
    $Window.Add_KeyDown({
            if ($_.Key -eq "Escape" -and $script:IsFullscreen) {
                $Global:MainWindow.WindowState = "Normal"
                $Global:MainWindow.Topmost = $false
                $Global:MainWindow.Left = $script:LastRect.Left
                $Global:MainWindow.Top = $script:LastRect.Top
                $Global:MainWindow.Width = $script:LastRect.Width
                $Global:MainWindow.Height = $script:LastRect.Height
                $btnFullscreen.Content = "⛶"
                $script:IsFullscreen = $false
            }
        })
    
    # 搜索框
    $searchBox = $Window.FindName("SearchBox")
    $searchBox.Add_TextChanged({
            $placeholder = $Window.FindName("SearchPlaceholder")
            if ($searchBox.Text.Length -gt 0) {
                $placeholder.Visibility = [System.Windows.Visibility]::Collapsed
            }
            else {
                $placeholder.Visibility = [System.Windows.Visibility]::Visible
            }
            Find-Tools -Window $Window -Keyword $searchBox.Text
        })

    # 主题切换（$args[0] = ComboBox 自身）
    $cmbTheme = $Window.FindName("CmbTheme")
    $cmbTheme.Add_DropDownClosed({
            $combo = $args[0]
            $item = $combo.SelectedItem
            Write-Log ">>> 主题选择: item=$item, Tag=$($item.Tag)" -Type Info
            if ($item -and $item.Tag) {
                $tag = $item.Tag.ToString()
                if ($tag -ne $script:CurrentTheme) {
                    Apply-Theme $tag
                    Save-ThemePreference
                }
            }
        })

    # 快速入口卡片（欢迎页点击）
    $contentControl = $Window.FindName("ToolContent")
}

# ---------- 绑定快速入口卡片事件 ----------
function Register-WelcomeCards {
    param($Window)
    
    # 递归查找 Border 中带有 Tag 的快速卡片
    $welcomePanel = $Window.FindName("WelcomePanel")
    if (-not $welcomePanel) { return }
    
    function Find-Cards($parent) {
        if ($parent -is [System.Windows.Controls.Border] -and $parent.Tag) {
            # 捕获当前 Border 引用，防止闭包中 $parent 被覆盖
            $cardBorder = $parent
            $cardTag = $parent.Tag.ToString()
            $cardBorder.Add_MouseLeftButtonDown({
                    if ($cardTag) {
                        # 在 TreeView 中查找对应工具并选中
                        $tree = $Window.FindName("ToolTree")
                        foreach ($parentNode in $tree.Items) {
                            foreach ($child in $parentNode.Items) {
                                $cfg = $child.Tag
                                if ($cfg -and $cfg.Name -eq $cardTag) {
                                    $child.IsSelected = $true
                                    Set-Tool -Window $Window -ToolConfig $cfg
                                    return
                                }
                            }
                        }
                    }
                })
            # 同时给内部子元素绑定事件（防止点击到 TextBlock 时无法触发）
            if ($cardBorder.Child -is [System.Windows.Controls.Panel]) {
                $cardBorder.Child.Add_MouseLeftButtonDown({
                        if ($cardTag) {
                            $tree = $Window.FindName("ToolTree")
                            foreach ($parentNode in $tree.Items) {
                                foreach ($child in $parentNode.Items) {
                                    $cfg = $child.Tag
                                    if ($cfg -and $cfg.Name -eq $cardTag) {
                                        $child.IsSelected = $true
                                        Set-Tool -Window $Window -ToolConfig $cfg
                                        return
                                    }
                                }
                            }
                        }
                    })
            }
        }
        if ($parent -is [System.Windows.Controls.Panel]) {
            foreach ($child in $parent.Children) {
                Find-Cards $child
            }
        }
    }
    Find-Cards $welcomePanel
}

# ---------- 主入口 ----------
function Main {
    # 加载 XAML
    if (-not $script:EmbeddedXamlB64 -and -not (Test-Path $script:XamlPath)) {
        Write-Log "错误: XAML 文件不存在 - $script:XamlPath" -Type Error
        return
    }
    
    $window = Import-Xaml -Path $script:XamlPath
    $Global:MainWindow = $window
    
    # 加载配置
    $configs = Import-ToolConfigs
    if (-not $configs) {
        Write-Log "错误: 无法加载工具配置" -Type Error
        return
    }
    $script:ToolConfigs = $configs
    
    # 构建导航树
    Initialize-TreeView -Window $window -Configs $configs
    
    # 绑定事件
    Register-Events -Window $window
    Register-WelcomeCards -Window $window

    # 初始化主题（必须在 Register-Events 之后，因为 ComboBox 事件需要已绑定）
    Initialize-Theme

    # 初始化内容区域
    # Initialize-Content -Window $window
    # Set-Tool -Window $window -ToolConfig $configs[0] # 默认选中第一个工具
    
    # 启动日志
    Write-Log "Gemini 启动成功，共加载 $($configs.Count) 个工具" -Type Success
    
    # 显示窗口
    $window.ShowDialog() | Out-Null
}

# ---------- 启动 ----------
Main

