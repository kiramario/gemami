# ============================================================
#  文件重命名工具
# ============================================================
Write-ToolLog "正在加载文件重命名工具..." -Type Info

# 返回 XAML UI 控件
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
    <TextBlock Text="📝 文件批量重命名" FontSize="20" FontWeight="Bold" 
               Foreground="#333333" Margin="0,0,0,15"/>
    
    <!-- 目录选择 -->
    <Grid Grid.Row="1" Margin="0,0,0,10">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="70"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="目标目录:" VerticalAlignment="Center" FontSize="13"/>
        <TextBox x:Name="FolderPath" Grid.Column="1" VerticalAlignment="Center" 
                 Height="28" Margin="5,0" IsReadOnly="True"
                 Background="#F5F5F5" BorderBrush="#CCCCCC"/>
        <Button x:Name="BtnBrowse" Grid.Column="2" Content="📂 浏览" Width="80" Height="28"
                Background="#0078D4" Foreground="White" BorderThickness="0" 
                Cursor="Hand" Padding="10,0"/>
    </Grid>
    
    <!-- 重命名规则 -->
    <Border Grid.Row="2" Background="White" CornerRadius="6" Padding="15" Margin="0,0,0,10">
        <Border.Effect>
            <DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.1"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="70"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="80"/>
            </Grid.ColumnDefinitions>
            
            <TextBlock Text="查找:" VerticalAlignment="Center" FontSize="13"/>
            <TextBox x:Name="FindText" Grid.Column="1" Height="28" Margin="5,0,5,8"
                     VerticalAlignment="Center"/>
            
            <TextBlock Grid.Row="1" Text="替换为:" VerticalAlignment="Center" FontSize="13"/>
            <TextBox x:Name="ReplaceText" Grid.Row="1" Grid.Column="1" Height="28" 
                     Margin="5,0,5,8" VerticalAlignment="Center"/>
            
            <TextBlock Grid.Row="2" Text="添加前缀:" VerticalAlignment="Center" FontSize="13"/>
            <TextBox x:Name="Prefix" Grid.Row="2" Grid.Column="1" Height="28"
                     Margin="5,0,5,8" VerticalAlignment="Center"/>
            
            <TextBlock Grid.Row="3" Text="添加后缀:" VerticalAlignment="Center" FontSize="13"/>
            <TextBox x:Name="Suffix" Grid.Row="3" Grid.Column="1" Height="28"
                     Margin="5,0,5,0" VerticalAlignment="Center"/>
            
            <CheckBox x:Name="ChkUseRegex" Grid.Row="1" Grid.Column="2" 
                      Content="正则" VerticalAlignment="Center" FontSize="12" Margin="0,0,0,8"/>
        </Grid>
    </Border>
    
    <!-- 文件预览列表 -->
    <Border Grid.Row="3" Background="White" CornerRadius="6" Padding="10">
        <Border.Effect>
            <DropShadowEffect BlurRadius="5" ShadowDepth="1" Opacity="0.1"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="📋 文件预览" FontSize="13" FontWeight="SemiBold" 
                           VerticalAlignment="Center" Foreground="#333333"/>
                <TextBlock x:Name="FileCount" Text="（共 0 个文件）" FontSize="12" 
                           Foreground="#888888" VerticalAlignment="Center" Margin="5,0,0,0"/>
            </StackPanel>
            <ListView x:Name="FileList" Grid.Row="1" BorderThickness="0" 
                      Background="#FAFAFA" SelectionMode="Extended">
                <ListView.View>
                    <GridView>
                        <GridViewColumn Header="原文件名" Width="220" DisplayMemberBinding="{Binding OriginalName}"/>
                        <GridViewColumn Header="预览" Width="220" DisplayMemberBinding="{Binding Preview}"/>
                        <GridViewColumn Header="大小" Width="80" DisplayMemberBinding="{Binding Size}"/>
                        <GridViewColumn Header="修改日期" Width="140" DisplayMemberBinding="{Binding Date}"/>
                    </GridView>
                </ListView.View>
            </ListView>
        </Grid>
    </Border>
    
    <!-- 操作按钮 -->
    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
        <Button x:Name="BtnPreview" Content="👁 预览" Width="100" Height="32"
                Background="#F0F0F0" Foreground="#333333" BorderBrush="#CCCCCC" 
                Cursor="Hand" Margin="0,0,10,0"/>
        <Button x:Name="BtnRename" Content="✅ 执行重命名" Width="120" Height="32"
                Background="#0078D4" Foreground="White" BorderThickness="0" 
                Cursor="Hand"/>
    </StackPanel>
</Grid>
'@

# 加载 XAML
$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)

$script:SelectedFolder = $null
$script:AllFiles = @()

# ---------- 预览重命名效果 ----------
function Update-Preview {
    $findText = $ui.FindName("FindText").Text
    $replaceText = $ui.FindName("ReplaceText").Text
    $prefix = $ui.FindName("Prefix").Text
    $suffix = $ui.FindName("Suffix").Text
    $useRegex = $ui.FindName("ChkUseRegex").IsChecked
    
    $fileList = $ui.FindName("FileList")
    $fileList.Items.Clear()
    
    $count = 0
    foreach ($file in $script:AllFiles) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $ext = [System.IO.Path]::GetExtension($file.Name)
        
        # 应用替换
        if ($findText) {
            if ($useRegex) {
                try { $baseName = $baseName -replace $findText, $replaceText }
                catch { }
            }
            else {
                $baseName = $baseName.Replace($findText, $replaceText)
            }
        }
        
        # 添加前缀/后缀
        $newName = "$prefix$baseName$suffix$ext"
        
        if ($newName -ne $file.Name) {
            $fileList.Items.Add([PSCustomObject]@{
                OriginalName = $file.Name
                Preview = $newName
                Size = if ($file.Length -gt 1MB) { "{0:N1} MB" -f ($file.Length / 1MB) } 
                       elseif ($file.Length -gt 1KB) { "{0:N1} KB" -f ($file.Length / 1KB) }
                       else { "$($file.Length) B" }
                Date = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                FileInfo = $file
                NewName = $newName
            })
            $count++
        }
    }
    
    $ui.FindName("FileCount").Text = "（共 $count 个文件需要重命名）"
    Write-ToolLog "预览完成: $count 个文件将重命名" -Type Info
}

# ---------- 按钮事件 ----------
$btnBrowse = $ui.FindName("BtnBrowse")
$btnBrowse.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "选择要重命名的文件夹"
    if ($dialog.ShowDialog() -eq "OK") {
        $script:SelectedFolder = $dialog.SelectedPath
        $ui.FindName("FolderPath").Text = $dialog.SelectedPath
        
        # 加载文件列表
        $script:AllFiles = Get-ChildItem -Path $dialog.SelectedPath -File | 
                           Sort-Object Name
        Write-ToolLog "已加载 $($script:AllFiles.Count) 个文件" -Type Success
        Update-Preview
    }
})

$btnPreview = $ui.FindName("BtnPreview")
$btnPreview.Add_Click({ Update-Preview })

$btnRename = $ui.FindName("BtnRename")
$btnRename.Add_Click({
    $items = $ui.FindName("FileList").Items
    if ($items.Count -eq 0) {
        Write-ToolLog "没有需要重命名的文件" -Type Warning
        return
    }
    
    $success = 0
    $fail = 0
    foreach ($item in $items) {
        try {
            $oldPath = Join-Path $script:SelectedFolder $item.OriginalName
            $newPath = Join-Path $script:SelectedFolder $item.NewName
            Rename-Item -Path $oldPath -NewName $newPath -ErrorAction Stop
            Write-ToolLog "✅ $($item.OriginalName) → $($item.NewName)" -Type Success
            $success++
        }
        catch {
            Write-ToolLog "❌ $($item.OriginalName): $($_.Exception.Message)" -Type Error
            $fail++
        }
    }
    
    Write-ToolLog "操作完成: 成功 $success 个, 失败 $fail 个" -Type $(if ($fail -eq 0) { "Success" } else { "Warning" })
    
    # 刷新
    $script:AllFiles = Get-ChildItem -Path $script:SelectedFolder -File | Sort-Object Name
    Update-Preview
})

# 搜索框文本变化实时预览
$ui.FindName("FindText").Add_TextChanged({ Update-Preview })
$ui.FindName("ReplaceText").Add_TextChanged({ Update-Preview })
$ui.FindName("Prefix").Add_TextChanged({ Update-Preview })
$ui.FindName("Suffix").Add_TextChanged({ Update-Preview })
$ui.FindName("ChkUseRegex").Add_Checked({ Update-Preview })
$ui.FindName("ChkUseRegex").Add_Unchecked({ Update-Preview })

Write-ToolLog "文件重命名工具就绪" -Type Success
return $ui

