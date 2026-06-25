# ============================================================
#  文件分类整理工具
# ============================================================
Write-ToolLog "正在加载文件分类整理工具..." -Type Info

$xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 标题 -->
    <TextBlock Text="📂 文件分类整理" FontSize="20" FontWeight="Bold" 
               Foreground="#333333" Margin="0,0,0,10"/>

    <!-- 主内容区 -->
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <StackPanel>
            <!-- 目录选择 -->
            <Border Background="White" CornerRadius="6" Padding="15" Margin="0,0,0,8">
                <Border.Effect>
                    <DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.1"/>
                </Border.Effect>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="80"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="源目录:" VerticalAlignment="Center" FontSize="13" FontWeight="SemiBold"/>
                    <TextBox x:Name="SourceFolder" Grid.Column="1" Height="28" 
                             VerticalAlignment="Center" IsReadOnly="True"
                             Background="#F5F5F5" BorderBrush="#CCCCCC"/>
                    <Button x:Name="BtnBrowse" Grid.Column="2" Content="📂 浏览" Width="80" Height="28"
                            Background="#0078D4" Foreground="White" BorderThickness="0" 
                            Cursor="Hand" Margin="10,0,0,0"/>
                </Grid>
            </Border>

            <!-- 分类规则 -->
            <Border Background="White" CornerRadius="6" Padding="15" Margin="0,0,0,8">
                <Border.Effect>
                    <DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.1"/>
                </Border.Effect>
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    
                    <TextBlock Text="⚙ 分类规则" FontSize="14" FontWeight="SemiBold" 
                               Foreground="#333333" Margin="0,0,0,10"/>
                    
                    <!-- 按扩展名 -->
                    <StackPanel Grid.Row="1" Margin="0,0,0,10">
                        <CheckBox x:Name="ChkByExt" Content="按文件类型分类（图片/文档/视频/压缩包/其他）" 
                                  IsChecked="True" FontSize="13" Margin="0,0,0,5"/>
                        <TextBlock Text="将文件按扩展名自动归类到对应文件夹" FontSize="11" 
                                   Foreground="#888888" Margin="20,0,0,0"/>
                    </StackPanel>
                    
                    <!-- 按日期 -->
                    <StackPanel Grid.Row="2">
                        <CheckBox x:Name="ChkByDate" Content="按修改日期分类" 
                                  FontSize="13" Margin="0,0,0,5"/>
                        <StackPanel Orientation="Horizontal" Margin="20,0,0,5">
                            <RadioButton x:Name="DateByYear" Content="按年" IsChecked="True" 
                                         FontSize="12" Margin="0,0,15,0" GroupName="DateGroup"/>
                            <RadioButton x:Name="DateByMonth" Content="按年/月" 
                                         FontSize="12" GroupName="DateGroup"/>
                        </StackPanel>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- 分类示意图 -->
            <Border Background="White" CornerRadius="6" Padding="15" Margin="0,0,0,8">
                <Border.Effect>
                    <DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.1"/>
                </Border.Effect>
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="📁 目录结构预览" FontSize="14" FontWeight="SemiBold" 
                                   Foreground="#333333" Margin="0,0,0,8"/>
                        <TextBlock x:Name="FileCount" Text="（请先选择源目录）" FontSize="12" 
                                   Foreground="#888888" VerticalAlignment="Center" Margin="8,0,0,4"/>
                    </StackPanel>
                    <TreeView x:Name="DirTree" Grid.Row="1" Height="220" Background="#FAFAFA" 
                              BorderBrush="#E0E0E0" BorderThickness="1" Margin="0,5,0,0"/>
                </Grid>
            </Border>
        </StackPanel>
    </ScrollViewer>

    <!-- 操作按钮 -->
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
        <Button x:Name="BtnPreview" Content="👁 预览" Width="100" Height="32"
                Background="#F0F0F0" Foreground="#333333" BorderBrush="#CCCCCC" 
                Cursor="Hand" Margin="0,0,10,0"/>
        <Button x:Name="BtnClassify" Content="📂 执行分类" Width="120" Height="32"
                Background="#0078D4" Foreground="White" BorderThickness="0" 
                Cursor="Hand"/>
    </StackPanel>
</Grid>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)

$script:SourceDir = $null
$script:AllFiles = @()

# ---------- 扩展名映射 ----------
$ExtensionMap = @{
    '图片'   = @('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.ico', '.webp', '.svg', '.tiff', '.tif', '.psd', '.raw', '.heic')
    '文档'   = @('.txt', '.md', '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.csv', '.json', '.xml', '.html', '.htm', '.log')
    '视频'   = @('.mp4', '.avi', '.mkv', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp', '.rmvb', '.ts')
    '音频'   = @('.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a', '.ape', '.opus')
    '压缩包' = @('.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz', '.iso', '.cab', '.msi')
    '代码'   = @('.ps1', '.py', '.js', '.ts', '.java', '.cpp', '.c', '.h', '.cs', '.go', '.rs', '.rb', '.php', '.sql', '.sh', '.bat', '.cmd')
    '可执行' = @('.exe', '.dll', '.msi', '.pdb', '.bin')
}

function Get-CategoryByExt {
    param([string]$Ext)
    $extLower = $Ext.ToLower()
    foreach ($cat in $ExtensionMap.Keys) {
        if ($ExtensionMap[$cat] -contains $extLower) { return $cat }
    }
    return "其他"
}

# ---------- 构建目录树预览 ----------
function Build-Preview {
    $fileCount = 0
    
    $chkExt = $ui.FindName("ChkByExt").IsChecked
    $chkDate = $ui.FindName("ChkByDate").IsChecked
    $byMonth = $ui.FindName("DateByMonth").IsChecked

    $tree = $ui.FindName("DirTree")
    $tree.Items.Clear()

    if (-not $script:SourceDir -or $script:AllFiles.Count -eq 0) {
        $ui.FindName("FileCount").Text = "(请先选择源目录)"
        return
    }

    # 构建带 TargetPath 的文件列表
    $classified = @()
    foreach ($f in $script:AllFiles) {
        $ext = [System.IO.Path]::GetExtension($f.Name)
        $datePrefix = ""

        if ($chkDate) {
            $mtime = $f.LastWriteTime
            if ($byMonth) {
                $datePrefix = "$($mtime.Year)-$($mtime.Month.ToString('D2'))\"
            }
            else {
                $datePrefix = "$($mtime.Year)\"
            }
        }

        if ($chkExt) {
            $cat = Get-CategoryByExt -Ext $ext
            $targetDir = "$datePrefix$cat"
        }
        else {
            $cat = Get-CategoryByExt -Ext $ext  # still show category info
            $targetDir = $datePrefix.TrimEnd('\')
        }

        $classified += [PSCustomObject]@{
            File       = $f
            Ext        = $ext
            Category   = $cat
            TargetDir  = $targetDir.TrimEnd('\')
        }
    }

    $fileCount = $classified.Count

    # 按 TargetDir 分组构建树
    $groups = $classified | Group-Object -Property TargetDir | Sort-Object Name

    foreach ($group in $groups) {
        $dirName = $group.Name
        if ([string]::IsNullOrEmpty($dirName)) { $dirName = "(根目录)" }

        # 构建缩进路径
        $parts = $dirName -split '\\'
        $current = $tree.Items

        for ($i = 0; $i -lt $parts.Count; $i++) {
            $part = $parts[$i]
            $existing = $current | Where-Object { $_.Header -match [regex]::Escape($part) }
            
            if ($existing) {
                $node = $existing
            }
            else {
                $node = [System.Windows.Controls.TreeViewItem]::new()
                $icon = if ($i -eq $parts.Count - 1) {
                    # 叶子目录，显示文件数
                    "📁 $part ($($group.Count) 个文件)"
                }
                else {
                    "📂 $part"
                }
                $node.Header = $icon
                $node.FontSize = 13
                $node.Padding = [System.Windows.Thickness]::new(4, 2, 4, 2)
                $node.IsExpanded = $true

                if ($i -eq 0) {
                    $tree.Items.Add($node)
                }
                else {
                    $parentNode = $current[-1]
                    if ($parentNode) { $parentNode.Items.Add($node) }
                }
                $current = $node.Items
            }
        }

        # 最后一级添加文件预览（最多显示5个）
        $showCount = [Math]::Min(5, $group.Group.Count)
        for ($j = 0; $j -lt $showCount; $j++) {
            $item = $group.Group[$j]
            $fileNode = [System.Windows.Controls.TreeViewItem]::new()
            $fileNode.Header = $item.File.Name
            $fileNode.FontSize = 11
            $fileNode.Foreground = "#888888"
            $fileNode.Padding = [System.Windows.Thickness]::new(4, 1, 4, 1)
            
            if ($node) { $node.Items.Add($fileNode) }
        }
        if ($group.Group.Count -gt 5) {
            $moreNode = [System.Windows.Controls.TreeViewItem]::new()
            $moreNode.Header = "... 还有 $($group.Group.Count - 5) 个文件"
            $moreNode.FontSize = 11
            $moreNode.Foreground = "#AAAAAA"
            $moreNode.Padding = [System.Windows.Thickness]::new(4, 1, 4, 1)
            if ($node) { $node.Items.Add($moreNode) }
        }
    }

    $ui.FindName("FileCount").Text = "(共 $fileCount 个文件 → $($groups.Count) 个目录)"
    Write-ToolLog "预览完成: $fileCount 个文件, $($groups.Count) 个目标目录" -Type Success
}

# ---------- 执行分类 ----------
function Invoke-Classify {
    $chkExt = $ui.FindName("ChkByExt").IsChecked
    $chkDate = $ui.FindName("ChkByDate").IsChecked
    $byMonth = $ui.FindName("DateByMonth").IsChecked

    if (-not $script:SourceDir -or $script:AllFiles.Count -eq 0) {
        Write-ToolLog "没有文件可以分类" -Type Warning
        return
    }

    Write-ToolLog "开始文件分类..." -Type Info
    $moved = 0
    $skipped = 0
    $errors = 0

    foreach ($f in $script:AllFiles) {
        try {
            $ext = [System.IO.Path]::GetExtension($f.Name)
            $datePrefix = ""

            if ($chkDate) {
                $mtime = $f.LastWriteTime
                if ($byMonth) {
                    $datePrefix = "$($mtime.Year)-$($mtime.Month.ToString('D2'))\"
                }
                else {
                    $datePrefix = "$($mtime.Year)\"
                }
            }

            $cat = if ($chkExt) { Get-CategoryByExt -Ext $ext } else { Get-CategoryByExt -Ext $ext }
            $targetDirName = if ($chkExt) { "$datePrefix$cat" } else { $datePrefix.TrimEnd('\') }
            
            if ([string]::IsNullOrEmpty($targetDirName)) { continue }

            $targetDir = Join-Path $script:SourceDir $targetDirName
            if (-not (Test-Path $targetDir)) {
                $null = New-Item -Path $targetDir -ItemType Directory -Force
            }

            $targetPath = Join-Path $targetDir $f.Name

            # 处理重名
            if (Test-Path $targetPath) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                $extName = [System.IO.Path]::GetExtension($f.Name)
                $counter = 1
                while (Test-Path $targetPath) {
                    $targetPath = Join-Path $targetDir "$baseName`_$counter$extName"
                    $counter++
                }
            }

            Move-Item -Path $f.FullName -Destination $targetPath -Force -ErrorAction Stop
            $moved++
        }
        catch {
            Write-ToolLog "移动失败: $($f.Name) - $($_.Exception.Message)" -Type Error
            $errors++
        }
    }

    Write-ToolLog "分类完成: 移动 $moved 个, 跳过 $skipped 个, 失败 $errors 个" -Type $(if ($errors -eq 0) { "Success" } else { "Warning" })
    
    # 刷新
    $script:AllFiles = Get-ChildItem -Path $script:SourceDir -File -ErrorAction SilentlyContinue | Sort-Object Name
    Build-Preview
}

# ---------- 事件绑定 ----------
$ui.FindName("BtnBrowse").Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "选择要整理的文件夹"
    if ($dialog.ShowDialog() -eq "OK") {
        $script:SourceDir = $dialog.SelectedPath
        $ui.FindName("SourceFolder").Text = $dialog.SelectedPath
        $script:AllFiles = Get-ChildItem -Path $dialog.SelectedPath -File -ErrorAction SilentlyContinue | Sort-Object Name
        Write-ToolLog "已加载 $($script:AllFiles.Count) 个文件" -Type Success
        Build-Preview
    }
})

$ui.FindName("BtnPreview").Add_Click({ Build-Preview })
$ui.FindName("BtnClassify").Add_Click({ Invoke-Classify })

# 规则变化时重新预览
$ui.FindName("ChkByExt").Add_Click({ Build-Preview })
$ui.FindName("ChkByDate").Add_Click({ Build-Preview })
$ui.FindName("DateByYear").Add_Click({ Build-Preview })
$ui.FindName("DateByMonth").Add_Click({ Build-Preview })

Write-ToolLog "文件分类整理工具就绪" -Type Success
return $ui
