# ============================================================
#  Slideshow Maker
#  基于 ffmpeg 把指定目录的图片拼接成 mp4 轮播视频
#  特性:
#    1) 扫描源目录,为每张图分配 001/002... 唯一编号,写 manifest.txt
#    2) 不修改源文件;可选创建临时副本 (001.jpg, 002.jpg...)
#    3) 两种 ffmpeg 模式:
#       - 简单拼接 (concat demuxer) — 稳定,适合几百张纯展示
#       - filter_complex — 支持淡入淡出/横滑/竖滑过渡
#    4) 切片:每 N 张图生成一段 mp4
#    5) 可选 BGM + 淡入淡出
# ============================================================

if (-not (Get-Command Write-ToolLog -ErrorAction SilentlyContinue)) {
    # 独立模式 fallback: 写日志到文件,不依赖 Main.xaml 的 OutputLog
    # 路径优先级: $Global:GeminiToolsDir (嵌入开发) > $PSScriptRoot (独立跑) > $PWD
    $script:SmLogBase = if ($Global:GeminiToolsDir) { $Global:GeminiToolsDir }
    elseif ($PSScriptRoot) { $PSScriptRoot }
    else { $PWD.Path }
    $script:SmLogDir = Join-Path $script:SmLogBase '_logs'
    if (-not (Test-Path -LiteralPath $script:SmLogDir)) {
        New-Item -Path $script:SmLogDir -ItemType Directory -Force | Out-Null
    }
    $script:SmLogFile = Join-Path $script:SmLogDir ('SlideshowMaker_' + (Get-Date -Format 'yyyyMMdd') + '.log')

    function Global:Write-ToolLog {
        param([string]$Message, [string]$Type = "Info")
        $ts = (Get-Date).ToString('HH:mm:ss')
        $tag = switch ($Type) {
            'Warning' { 'WARN' }
            'Error' { 'ERROR' }
            'Success' { 'OK' }
            default { 'INFO' }
        }
        Add-Content -LiteralPath $script:SmLogFile -Value "[$ts] [$tag] $Message" -Encoding UTF8
    }
}

# ---------- ffmpeg 定位 ----------
$script:FfmpegExe = $null
$script:FfmpegDir = Join-Path $Global:GeminiToolsDir "lib\ffmpeg"
$script:FfmpegBundled = Join-Path $script:FfmpegDir "ffmpeg.exe"
if (Test-Path -LiteralPath $script:FfmpegBundled) {
    $script:FfmpegExe = $script:FfmpegBundled
}
else {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { $script:FfmpegExe = $cmd.Source }
}
$script:FfmpegOk = [bool]$script:FfmpegExe

# ---------- 主线程状态 ----------
$script:SmUi = $null
$script:SmRunning = $false
$script:SmStop = $false
$script:SmRs = $null
$script:SmPs = $null
$script:SmHandle = $null
$script:SmTimer = $null
$script:SmSync = $null
$script:SmStats = @{ DoneSegs = 0; TotalSegs = 0; CurSeg = 0; StartTime = $null }
$script:SmBrushCache = @{}

# ============================================================
#         主线程工具函数
# ============================================================
function Format-SmSize {
    param([long]$B)
    if ($B -ge 1MB) { '{0:N2} MB' -f ($B / 1MB) }
    elseif ($B -ge 1KB) { '{0:N2} KB' -f ($B / 1KB) } else { "$B B" }
}

function Scan-SmImages {
    param([string]$SrcDir, [string[]]$Exts, [string]$SortField, [string]$SortDir)
    $list = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $SrcDir)) { return , @() }
    $extsLower = $Exts | ForEach-Object { $_.ToLower() }
    Get-ChildItem -LiteralPath $SrcDir -File -ErrorAction SilentlyContinue | Where-Object {
        $ext = $_.Extension.TrimStart('.').ToLower()
        $extsLower -contains $ext
    } | ForEach-Object { $list.Add($_) }
    $asc = ($SortDir -eq 'Asc')
    $sorted = switch ($SortField) {
        'MTime' { $list | Sort-Object -Property LastWriteTime -Descending:(-not $asc) }
        default { $list | Sort-Object -Property Name -Descending:(-not $asc) }
    }
    return , @($sorted)
}

function Write-SmLog {
    param([string]$Message, [string]$Type = "Info")
    Write-ToolLog $Message $Type
}

# ============================================================
#         ffmpeg 引擎 (自包含,跑在 Runspace 中)
#         所有辅助函数都内联在 scriptblock 里
# ============================================================
$script:SmRunner = {
    param([hashtable]$Cfg, [hashtable]$Sync)
    $ErrorActionPreference = 'Stop'

    # ---- 工具闭包 ----
    $push = { param([string]$M, [string]$T = 'Info')
        $Sync.LogQueue.Enqueue([PSCustomObject]@{
                Time = (Get-Date).ToString('HH:mm:ss'); Type = $T; Text = $M
            })
    }
    $scaleFilter = {
        param([int]$W, [int]$H, [string]$Mode, [string]$Bg)
        switch ($Mode) {
            'crop' { "scale=$W`:$H`:force_original_aspect_ratio=increase,crop=$W`:$H,setsar=1" }
            'blur_bg' { "[0:v]scale=$W`:$H`:force_original_aspect_ratio=increase,boxblur=40,crop=$W`:$H,setsar=1[bg];[0:v]scale=$W`:$H`:force_original_aspect_ratio=decrease,setsar=1[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2:format=auto" }
            default { "scale=$W`:$H`:force_original_aspect_ratio=decrease,pad=$W`:$H`:(ow-iw)/2:(oh-ih)/2:$Bg,setsar=1" }
        }
    }

    # Ken Burns 效果:用 zoompan 让每张图内部产生缓慢推拉/缩放
    # mode: none|zoom_in|zoom_out|pan_left|pan_right|pan_up|pan_down
    # 内部已 scale 成 W:H 比例,zoompan 再施加动画
    $kenBurnsFilter = {
        param([int]$W, [int]$H, [int]$Fps, [double]$Dur, [string]$Mode)
        if ($Mode -eq 'none' -or [string]::IsNullOrEmpty($Mode)) { return "" }
        $d = [int]($Dur * $Fps)
        if ($d -lt 1) { $d = 1 }
        $expr = switch ($Mode) {
            'zoom_in' { "z='1.0+0.3*on/$d'" }
            'zoom_out' { "z='1.3-0.3*on/$d'" }
            'pan_left' { "z='1.3':x='(iw-iw/1.3)*on/$d':y='(ih-ih/1.3)/2'" }
            'pan_right' { "z='1.3':x='(iw-iw/1.3)*(1-on/$d)':y='(ih-ih/1.3)/2'" }
            'pan_up' { "z='1.3':x='(iw-iw/1.3)/2':y='(ih-ih/1.3)*(1-on/$d)'" }
            'pan_down' { "z='1.3':x='(iw-iw/1.3)/2':y='(ih-ih/1.3)*on/$d'" }
            default { "z='1.0'" }
        }
        "zoompan=$expr:d=$d:s=${W}x${H}:fps=$Fps,setsar=1"
    }

    # 胶片黑边(letterbox):在视频上下加黑条
    $letterboxFilter = {
        param([int]$W, [int]$H, [int]$BarPx)
        if ($BarPx -le 0) { return "" }
        $newH = $H + 2 * $BarPx
        "scale=$W`:$newH,crop=$W`:$H`:0:$BarPx,setsar=1"
    }

    # ---- 写 manifest ----
    $writeManifest = {
        param([string]$OutDir, $Items)
        $p = Join-Path $OutDir '_slideshow_manifest.txt'
        $ls = New-Object 'System.Collections.Generic.List[string]'
        [void]$ls.Add('# Slideshow manifest - generated ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        [void]$ls.Add('# Format: NUMBER`tFILENAME`tFULL_PATH`tSIZE_BYTES`tMTIME')
        $n = 0
        foreach ($it in $Items) {
            $n++
            $num = '{0:D3}' -f $n
            $ls.Add(($num + '`t' + $it.Name + '`t' + $it.FullName + '`t' + $it.Length + '`t' + $it.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))
        }
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllLines($p, $ls, $utf8Bom)
        $p
    }

    # ---- 创建临时副本(硬链接优先,失败回退复制) ----
    $makeTemp = {
        param($Items, [string]$SrcDir)
        $tmpDir = Join-Path $SrcDir '_slideshow_tmp'
        if (Test-Path -LiteralPath $tmpDir) {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $null = New-Item -Path $tmpDir -ItemType Directory -Force
        $mapped = New-Object 'System.Collections.Generic.List[object]'
        $n = 0
        foreach ($it in $Items) {
            $n++
            $num = '{0:D3}' -f $n
            $ext = [IO.Path]::GetExtension($it.FullName)
            $dst = Join-Path $tmpDir ($num + $ext)
            try {
                try { New-Item -ItemType HardLink -Path $dst -Target $it.FullName -ErrorAction Stop | Out-Null }
                catch { Copy-Item -LiteralPath $it.FullName -Destination $dst -Force }
                $mapped.Add([PSCustomObject]@{ Number = $num; FullName = $dst; OrigName = $it.FullName; Length = $it.Length })
            }
            catch {
                & $push ('  副本失败: ' + $it.FullName) Warning
            }
        }
        , $mapped.ToArray()
    }

    # ---- 主流程 ----
    try {
        $src = $Cfg.SourceDir
        $outDir = $Cfg.OutputDir
        $outBase = $Cfg.OutBaseName
        $imgDur = [double]$Cfg.ImgDur
        $w = [int]$Cfg.Width
        $h = [int]$Cfg.Height
        $fps = [int]$Cfg.Fps
        $bitrate = $Cfg.Bitrate
        $codec = $Cfg.Codec
        $bg = $Cfg.BgColor
        $scaleMd = $Cfg.ScaleMode
        $splitN = [int]$Cfg.SplitN
        $bgm = $Cfg.BgmFile
        $fadeIn = [double]$Cfg.FadeIn
        $fadeOut = [double]$Cfg.FadeOut
        $makeTmp = [bool]$Cfg.MakeTmpCopies
        $ffExe = $Cfg.FfmpegExe
        $mode = $Cfg.Mode
        $trans = $Cfg.Transition
        $transDur = [double]$Cfg.TransDur
        $kbMode = $Cfg.KenBurnsMode
        $letterboxPx = [int]$Cfg.LetterboxPx
        $watermark = $Cfg.Watermark
        $wmPos = $Cfg.WatermarkPos
        $wmOpacity = [double]$Cfg.WatermarkOpacity

        $null = New-Item -Path $outDir -ItemType Directory -Force

        $items = $Cfg.Items
        $total = $items.Count
        if ($total -eq 0) { & $push '无图片' Error; $Sync.Finished = $true; return }
        if ($splitN -le 0) { $splitN = $total }
        $segs = [Math]::Ceiling($total / [double]$splitN)
        $Sync.TotalSegs = $segs
        & $push ('共 {0} 张, 分 {1} 段' -f $total, $segs) Info

        # 临时副本
        $workingItems = $items
        if ($makeTmp) {
            $workingItems = & $makeTemp $items $src
        }

        # 写 manifest
        $mfp = & $writeManifest $outDir $items
        & $push ('Manifest: ' + $mfp) Success

        $workDir = Join-Path $outDir '_slideshow_work'
        $null = New-Item -Path $workDir -ItemType Directory -Force

        for ($seg = 0; $seg -lt $segs; $seg++) {
            if ($Sync.Stop) { break }
            $Sync.CurSeg = $seg + 1
            $start = $seg * $splitN
            $end = [Math]::Min($start + $splitN, $total)
            $segItems = @($workingItems[$start..($end - 1)])
            $segName = if ($segs -eq 1) { ($outBase + '.mp4') } else { ('{0}_part{1:D3}.mp4' -f $outBase, ($seg + 1)) }
            $outPath = Join-Path $outDir $segName
            & $push ('处理段 ' + ($seg + 1) + '/' + $segs + ': ' + $segName) Info

            $partDir = Join-Path $workDir ('seg' + ('{0:D3}' -f ($seg + 1)))
            $null = New-Item -Path $partDir -ItemType Directory -Force

            # 每张图 → 一段 mp4
            $i = 0
            foreach ($it in $segItems) {
                $i++
                $partFile = Join-Path $partDir ('{0:D3}.mp4' -f $i)
                # 滤镜链:基础缩放 → Ken Burns → 胶片黑边
                $scaleV = & $scaleFilter $w $h $scaleMd $bg
                $kbV = & $kenBurnsFilter $w $h $fps $imgDur $kbMode
                $lbV = & $letterboxFilter $w $h $letterboxPx
                $vfParts = @($scaleV)
                if ($kbV) { $vfParts += $kbV }
                if ($lbV) { $vfParts += $lbV }
                $vf = $vfParts -join ','
                $args = @('-y', '-loop', '1', '-t', $imgDur, '-i', $it.FullName,
                    '-vf', $vf, '-r', $fps, '-c:v', $codec, '-pix_fmt', 'yuv420p',
                    '-b:v', $bitrate, '-an', $partFile)
                $p = Start-Process -FilePath $ffExe -ArgumentList $args -NoNewWindow -Wait -PassThru `
                    -RedirectStandardError (Join-Path $partDir ('{0:D3}.log' -f $i)) `
                    -WorkingDirectory $outDir
                if ($p.ExitCode -ne 0) {
                    & $push ('  图 ' + $i + ' 转码失败 exit=' + $p.ExitCode) Error
                }
            }

            # concat demuxer
            $listFile = Join-Path $partDir 'concat.txt'
            $confLines = New-Object 'System.Collections.Generic.List[string]'
            for ($k = 1; $k -le $segItems.Count; $k++) {
                $confLines.Add(('file ''' + ('{0:D3}.mp4' -f $k) + ''''))
            }
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllLines($listFile, $confLines, $utf8)

            $cfArgs = @('-y', '-f', 'concat', '-safe', '0', '-i', $listFile)
            if ($bgm -and (Test-Path -LiteralPath $bgm)) {
                $cfArgs += @('-i', $bgm, '-map', '0:v', '-map', '1:a?', '-c:v', 'copy', '-c:a', 'aac', '-shortest')
            }
            else {
                $cfArgs += @('-c', 'copy')
            }
            $cfArgs += $outPath
            $p = Start-Process -FilePath $ffExe -ArgumentList $cfArgs -NoNewWindow -Wait -PassThru `
                -RedirectStandardError (Join-Path $partDir 'concat.log') `
                -WorkingDirectory $partDir
            if ($p.ExitCode -ne 0) {
                & $push ('  Segment ' + ($seg + 1) + ' 合成失败 exit=' + $p.ExitCode) Error
                continue
            }
            Remove-Item -LiteralPath $partDir -Recurse -Force -ErrorAction SilentlyContinue

            # 水印叠加 (可选):在合成后的视频上加 logo
            if ($watermark -and (Test-Path -LiteralPath $watermark)) {
                $tmpPath = $outPath + '.tmp.mp4'
                $pos = switch ($wmPos) {
                    'topleft' { '10:10' }
                    'topright' { 'W-w-10:10' }
                    'bottomleft' { '10:H-h-10' }
                    default { 'W-w-10:H-h-10' }
                }
                $overlay = ('overlay=' + $pos + ':format=auto')
                if ($wmOpacity -lt 1.0) {
                    # 带透明度:把水印转 RGBA,调 alpha,然后 overlay
                    $fc = ('[1:v]format=yuva420p,colorchannelmixer=aa=' + $wmOpacity + '[wm];[0:v][wm]' + $overlay)
                    $wmArgs = @('-y', '-i', $outPath, '-i', $watermark,
                        '-filter_complex', $fc,
                        '-map', '0:a?', '-c:v', $codec, '-c:a', 'copy',
                        '-pix_fmt', 'yuv420p', '-b:v', $bitrate, '-shortest', $tmpPath)
                }
                else {
                    $wmArgs = @('-y', '-i', $outPath, '-i', $watermark,
                        '-filter_complex', ('[0:v]' + $overlay),
                        '-map', '0:v', '-map', '1:v', '-map', '0:a?', '-c:v', $codec, '-c:a', 'copy',
                        '-pix_fmt', 'yuv420p', '-b:v', $bitrate, '-shortest', $tmpPath)
                }
                $wp = Start-Process -FilePath $ffExe -ArgumentList $wmArgs -NoNewWindow -Wait -PassThru `
                    -RedirectStandardError (Join-Path $workDir 'wm.log') `
                    -WorkingDirectory $workDir
                if ($wp.ExitCode -eq 0 -and (Test-Path -LiteralPath $tmpPath)) {
                    Move-Item -LiteralPath $tmpPath -Destination $outPath -Force
                    & $push ('    水印已加') Info
                }
                else {
                    & $push ('    水印叠加失败,保留原视频') Warning
                    if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force }
                }
            }

            & $push ('  Segment ' + ($seg + 1) + ' Done: ' + $outPath) Success
            $Sync.DoneSegs++
        }

        # 清临时副本
        if ($makeTmp) {
            $tmp = Join-Path $src '_slideshow_tmp'
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue

        if ($Sync.Stop) { & $push 'Stopped (completed segments preserved)' Warning }
        else { & $push 'All done' Success }
    }
    catch {
        & $push ('Main loop exception: ' + $_) Error
        $Sync.LastError = $_.ToString()
    }
    finally {
        $Sync.Finished = $true
    }
}

# ============================================================
#         主线程:启动/停止/进度刷新
# ============================================================
function Start-SmRun {
    if (-not $script:FfmpegOk) {
        & $script:fnWriteSmLog "ffmpeg.exe not found: put it under Tools\lib\ffmpeg\ or add to system PATH" Error
        [System.Windows.MessageBox]::Show(
            "can not find ffmpeg.exe: put it under Tools\lib\ffmpeg\ or add to system PATH",
            "pic slide show", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    $ui = $script:SmUi
    $src = (& $script:fnF 'TxtSource').Text.Trim()
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { & $script:fnWriteSmLog "源目录无效" Error; return }
    $outDir = (& $script:fnF 'TxtOutput').Text.Trim()
    if (-not $outDir) {
        $outDir = $src
        (& $script:fnF 'TxtOutput').Text = $src
    }
    $outBase = (& $script:fnF 'TxtOutBase').Text.Trim()
    if (-not $outBase) { $outBase = "slideshow"; (& $script:fnF 'TxtOutBase').Text = "slideshow" }

    $exts = @()
    if ((& $script:fnF 'ChkJpg').IsChecked) { $exts += 'jpg', 'jpeg' }
    if ((& $script:fnF 'ChkPng').IsChecked) { $exts += 'png' }
    if ((& $script:fnF 'ChkBmp').IsChecked) { $exts += 'bmp' }
    if ((& $script:fnF 'ChkWebp').IsChecked) { $exts += 'webp' }
    if (-not $exts) { & $script:fnWriteSmLog "至少选一种图片类型" Error; return }
    $sortField = if ((& $script:fnF 'CmbSort').Text -like '*日期*') { 'MTime' } else { 'Name' }
    $sortDir = if ((& $script:fnF 'CmbOrder').Text -like '*降*') { 'Desc' } else { 'Asc' }

    $items = & $script:fnScanSmImages $src $exts $sortField $sortDir
    if ($items.Count -eq 0) { & $script:fnWriteSmLog "未找到图片" Error; return }
    & $script:fnWriteSmLog ('扫描到 {0} 张图片' -f $items.Count) Success

    # 分辨率
    $resTxt = (& $script:fnF 'CmbRes').Text
    if ($resTxt -like '*原图*') {
        try {
            $firstImg = [System.Drawing.Image]::FromFile($items[0].FullName)
            $w = [int]$firstImg.Width; $h = [int]$firstImg.Height
            $firstImg.Dispose()
        }
        catch {
            & $script:fnWriteSmLog "无法读取原图尺寸,默认 1920x1080" Warning
            $w = 1920; $h = 1080
        }
    }
    elseif ($resTxt -match '(\d+)\s*x\s*(\d+)') {
        $w = [int]$Matches[1]; $h = [int]$Matches[2]
    }
    else {
        $w = 1920; $h = 1080
    }
    $fps = [int](& $script:fnF 'TxtFps').Text
    $bitrate = (& $script:fnF 'TxtBitrate').Text + 'M'
    $codec = (& $script:fnF 'CmbCodec').Text
    $imgDur = [double](& $script:fnF 'TxtImgDur').Text
    # Ken Burns
    $kbTxt = (& $script:fnF 'CmbKb').Text
    $kbMode = if ($kbTxt -like '*放大*') { 'zoom_in' }
    elseif ($kbTxt -like '*缩小*') { 'zoom_out' }
    elseif ($kbTxt -like '*右→左*') { 'pan_right' }
    elseif ($kbTxt -like '*左→右*') { 'pan_left' }
    elseif ($kbTxt -like '*上→下*') { 'pan_down' }
    elseif ($kbTxt -like '*下→上*') { 'pan_up' }
    else { 'none' }
    $letterboxPx = [int](& $script:fnF 'TxtLetterbox').Text
    $watermark = (& $script:fnF 'TxtWatermark').Text.Trim()
    $wmPosTxt = (& $script:fnF 'CmbWmPos').Text
    $wmPos = if ($wmPosTxt -like '*左上*') { 'topleft' }
    elseif ($wmPosTxt -like '*右上*') { 'topright' }
    elseif ($wmPosTxt -like '*左下*') { 'bottomleft' }
    else { 'bottomright' }
    $wmOpacity = [double](& $script:fnF 'TxtWmOpacity').Text
    $transDur = [double](& $script:fnF 'TxtTransDur').Text
    $scaleMode = if ((& $script:fnF 'CmbScale').Text -like '*裁剪*') { 'crop' }
    elseif ((& $script:fnF 'CmbScale').Text -like '*模糊*') { 'blur_bg' }
    else { 'contain' }
    $bgColor = (& $script:fnF 'TxtBgColor').Text
    if (-not $bgColor) { $bgColor = 'black' }
    $bgm = (& $script:fnF 'TxtBgm').Text.Trim()
    $fadeIn = [double](& $script:fnF 'TxtFadeIn').Text
    $fadeOut = [double](& $script:fnF 'TxtFadeOut').Text

    # ====== 选中效果 ======
    $effectName = (& $script:fnF 'CmbEffect').Text
    $effect = $script:SmEffects | Where-Object { $_.DisplayName -eq $effectName } | Select-Object -First 1
    if (-not $effect) {
        & $script:fnWriteSmLog "No effect selected. Please scan directory ffmpeg-video-slideshow-scripts/ first" Error
        return
    }
    if (-not (Test-Path -LiteralPath $effect.Path)) {
        & $script:fnWriteSmLog "Effect script not found: $($effect.Path)" Error
        return
    }
    Write-Host "Selected effect: $effect"

    # ====== 写 manifest ======
    $mfLines = New-Object 'System.Collections.Generic.List[string]'
    $n = 0
    foreach ($it in $items) {
        $n++
        $mfLines.Add(('{0:D3}|{1}|{2}' -f $n, $it.Name, $it.FullName))
    }
    $mfPath = Join-Path $outDir ($outBase + '.manifest.txt')
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllLines($mfPath, $mfLines, $utf8Bom)
    & $script:fnWriteSmLog ('Manifest: ' + $mfPath) Success

    # ====== 准备脚本参数 ======
    $imagePaths = @()
    foreach ($it in $items) { $imagePaths += $it.FullName }
    $outPath = Join-Path $outDir ($outBase + '.mp4')

    # 转换 watermark 位置到脚本标准
    $wmPosScript = switch ($wmPos) {
        'topleft' { 'TL' }
        'topright' { 'TR' }
        'bottomleft' { 'BL' }
        default { 'BR' }
    }

    $scriptArgs = @{
        Images             = $imagePaths
        OutputPath         = $outPath
        Width              = $w
        Height             = $h
        Fps                = $fps
        ImageDuration      = $imgDur
        TransitionDuration = $transDur
        ScaleMode          = $scaleMode
        BackgroundColor    = $bgColor
        KenBurns           = $kbMode
        WatermarkPath      = $watermark
        WatermarkPosition  = $wmPosScript
        WatermarkOpacity   = $wmOpacity
        LetterboxPx        = $letterboxPx
        BgmPath            = $bgm
        BgmFadeIn          = $fadeIn
        BgmFadeOut         = $fadeOut
    }

    # ====== 同步调用效果脚本(GUI 会临时冻结,Stage 2 可改成 Runspace/Job) ======
    (& $script:fnF 'BtnStart').IsEnabled = $false
    (& $script:fnF 'BtnStop').IsEnabled = $true
    (& $script:fnF 'TxtSource').IsEnabled = $false
    (& $script:fnF 'TxtOutput').IsEnabled = $false
    (& $script:fnF 'TxtStatus').Text = "运行: $($effect.DisplayName)"

    & $script:fnWriteSmLog ('Dispatch: ' + $effect.DisplayName) Success

    try {
        # ⚠️ effect 脚本的 filter_complex 在大图数时会非常大(每张图 200+ 字符)。
        #   32K 命令行上限决定段大小:50 张图 filter_complex ~13K + xfade 链 ~3K + 短路径 input ~2K = ~18K 字符
        #   比之前的 30 张更宽(临时目录短路径减少 input 部分)。
        # ⚠️ 创建临时副本:1000 张图从 img0001.jpg(14 字符)重命名为 001.jpg(7 字符),
        #   input 命令长度减少 ~10K,允许段大小从 30 升到 50。
        $maxBatch = 50
        $totalImgs = $scriptArgs.Images.Count
        if ($totalImgs -lt 1) { & $script:fnWriteSmLog "Images is empty, abort" Error; return }
        & $script:fnWriteSmLog ("TotalImages={0}, ScaleMode={1}, EffectPath={2}" -f $totalImgs, $scriptArgs.ScaleMode, $effect.Path) Info

        # 创建临时目录 + 硬链接(用户方案 A:在源目录创建临时文件夹,命名规律)
        $tmpDir = $null
        $workImgs = $scriptArgs.Images
        if ($totalImgs -gt $maxBatch) {
            $tmpDir = Join-Path $Cfg.SourceDir '_slideshow_tmp'
            # 等等,$Cfg.SourceDir 不可用,直接从源目录找
            # SlideshowMaker 扫描的源目录 = items[0].DirectoryName
            $srcDir = Split-Path -Parent $scriptArgs.Images[0]
            $tmpDir = Join-Path $srcDir '_slideshow_tmp'
            if ([string]::IsNullOrWhiteSpace($tmpDir)) { & $script:fnWriteSmLog "Cannot derive temp dir from $($scriptArgs.Images[0])" Error; return }
            if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
            try { $null = New-Item -ItemType Directory -Force -Path $tmpDir }
            catch { & $script:fnWriteSmLog ("Create temp dir failed: {0}" -f $_.Exception.Message) Error; return }
            $workImgs = @()
            $n = 0
            foreach ($srcPath in $scriptArgs.Images) {
                if ([string]::IsNullOrWhiteSpace($srcPath)) { & $script:fnWriteSmLog ("Empty source path at index {0}, skip" -f $n) Warning; continue }
                $n++
                $num = '{0:D4}' -f $n
                $ext = [IO.Path]::GetExtension($srcPath)
                if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '.jpg' }
                $dst = Join-Path $tmpDir ($num + $ext)
                try { New-Item -ItemType HardLink -Path $dst -Target $srcPath -ErrorAction Stop | Out-Null }
                catch { Copy-Item -LiteralPath $srcPath -Destination $dst -Force }
                $workImgs += $dst
            }
            if ($workImgs.Count -eq 0) { & $script:fnWriteSmLog "No images after hardlink, abort" Error; if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }; return }
        }

        if ($totalImgs -gt $maxBatch) {
            $batches = [Math]::Ceiling($totalImgs / $maxBatch)
            & $script:fnWriteSmLog ("Image count {0} > {1}, auto-split into {2} batches (hardlinked to {3})" -f $totalImgs, $maxBatch, $batches, $tmpDir) Warning
            $tmpMp4s = @()
            for ($bi = 0; $bi -lt $batches; $bi++) {
                $segImgs = $workImgs[($bi * $maxBatch) .. ([Math]::Min(($bi + 1) * $maxBatch - 1, $totalImgs - 1))]
                $segOut = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("ssm_seg_{0:yyyyMMdd_HHmmss}_{1}.mp4" -f (Get-Date), $bi))
                $segArgs = @{} + $scriptArgs
                $segArgs.Images = $segImgs
                $segArgs.OutputPath = $segOut
                & $script:fnWriteSmLog ("Batch {0}/{1}: {2} images -> {3}" -f ($bi + 1), $batches, $segImgs.Count, $segOut) Info
                # 进入 effect 前打印 splatting keys 与首个图的路径长度,方便排查空值
                & $script:fnWriteSmLog ("  segArgs keys: {0} | firstImgLen={1} | scaleMode={2} | watermark='{3}' | bgm='{4}' | wmPos={5}" -f (($segArgs.Keys -join ',').Length, $($segImgs[0].Length), $segArgs.ScaleMode, $segArgs.WatermarkPath, $segArgs.BgmPath, $segArgs.WatermarkPosition) Info
                if ($script:SmStop) { if ($tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }; throw "User stopped" }
                & $effect.Path @segArgs
                if ($script:SmStop) { if ($tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }; throw "User stopped" }
                if (-not (Test-Path -LiteralPath $segOut)) { if ($tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }; throw "Batch $bi failed: $segOut not generated" }
                $tmpMp4s += $segOut
            }
            # 用 ffmpeg concat demuxer 合并所有段
            $concatList = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("ssm_concat_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date)))
            $lines = New-Object 'System.Collections.Generic.List[string]'
            foreach ($mp4 in $tmpMp4s) {
                # concat demuxer 要求 'file' 关键字,路径中的单引号/反斜杠需要转义
                $escPath = $mp4 -replace "'", "'\\''"
                $lines.Add("file '$escPath'")
            }
            [System.IO.File]::WriteAllLines($concatList, $lines, (New-Object System.Text.UTF8Encoding $false))
            & $script:fnWriteSmLog ("Concatenating {0} segments -> {1}" -f $tmpMp4s.Count, $scriptArgs.OutputPath) Info
            $ffExe = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
            if (-not $ffExe) { $ffExe = Join-Path (Split-Path $PSCommandPath -Parent) 'lib\ffmpeg\ffmpeg.exe' }
            $concatArgs = @('-y', '-f', 'concat', '-safe', '0', '-i', $concatList, '-c', 'copy', $scriptArgs.OutputPath)
            $p = Start-Process -FilePath $ffExe -ArgumentList $concatArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$concatList.stdout" -RedirectStandardError "$concatList.stderr"
            Remove-Item -LiteralPath $tmpMp4s, $concatList, "$concatList.stdout", "$concatList.stderr" -ErrorAction SilentlyContinue
            if ($p.ExitCode -ne 0) { if ($tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }; throw "ffmpeg concat failed: exit code $($p.ExitCode)" }
        }
        else {
            & $effect.Path @scriptArgs
        }

        # 清理临时目录
        if ($tmpDir -and (Test-Path -LiteralPath $tmpDir)) {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # 打印完整 ErrorRecord 信息,包含堆栈与出错脚本行号,便于定位 effect 内部哪个 -Path 接收到空值
        & $script:fnWriteSmLog ('Effect script exception: ' + $_.Exception.Message) Error
        try {
            & $script:fnWriteSmLog ('  ExceptionType: ' + $_.Exception.GetType().FullName) Error
            if ($_.ScriptStackTrace) { & $script:fnWriteSmLog ('  StackTrace:' + "`n" + $_.ScriptStackTrace) Error }
            else { & $script:fnWriteSmLog '  StackTrace: <empty>' Error }
            if ($_.InvocationInfo) {
                & $script:fnWriteSmLog ('  Invocation: {0}: line {1}' -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber) Error
                if ($_.InvocationInfo.Line) { & $script:fnWriteSmLog ('  Line: ' + $_.InvocationInfo.Line.Trim()) Error }
            }
            $binding = $_.Exception.ErrorRecord | Where-Object { $_ -and $_.FullyQualifiedErrorId -eq 'ParameterArgumentValidationError,Microsoft.PowerShell.Commands.WriteErrorException' }
            if (-not $binding) { $binding = $_.Exception }
            if ($binding.TargetObject -ne $null) { & $script:fnWriteSmLog ('  TargetObject: ' + $binding.TargetObject) Error }
            & $script:fnWriteSmLog ('  TargetSite: ' + $_.Exception.TargetSite) Error
        } catch {}
        if ($tmpDir -and (Test-Path -LiteralPath $tmpDir)) {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        (& $script:fnF 'BtnStart').IsEnabled = $true
        (& $script:fnF 'BtnStop').IsEnabled = $false
        (& $script:fnF 'TxtSource').IsEnabled = $true
        (& $script:fnF 'TxtOutput').IsEnabled = $true
        (& $script:fnF 'TxtStatus').Text = "Done: $outPath"
        & $script:fnWriteSmLog "Done: $outPath" Success
    }
}

function Stop-SmRun {
    $script:SmStop = $true
    if ($script:SmSync) { $script:SmSync.Stop = $true }
    & $script:fnWriteSmLog "Stopping (will quit after current segment)..." Warning
}

function Script:Start-SmTimer {
    if ($script:SmTimer) { return }
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(400)
    $t.Add_Tick({
            $ui = $script:SmUi; $sync = $script:SmSync
            if (-not $ui -or -not $sync) { return }
            $e = $null; $n = 0
            while ($sync.LogQueue.TryDequeue([ref]$e) -and $n -lt 200) {
                $n++
                & $script:fnWriteSmLog $e.Text $e.Type
            }
            $total = $sync.TotalSegs; $done = $sync.DoneSegs; $cur = $sync.CurSeg
            (& $script:fnF 'TxtStatus').Text = if ($script:SmRunning) {
                if ($total -eq 0) { '准备中...' }
                elseif ($cur -gt 0) { "正在生成第 $cur / $total 段" }
                else { '排队中...' }
            }
            else { '空闲' }
            $prg = (& $script:fnF 'PrgProgress')
            if ($total -gt 0) {
                $prg.Maximum = 100
                $prg.Value = [Math]::Min(100, [int]($done * 100 / $total))
            }
            $el = if ($script:SmStats.StartTime) { (Get-Date) - $script:SmStats.StartTime } else { $null }
            if ($el) { $used = '{0:D2}:{1:D2}:{2:D2}' -f [int]$el.TotalHours, $el.Minutes, $el.Seconds } else { $used = '--:--' }
            (& $script:fnF 'TxtStats').Text = ('段: {0}/{1} | 已用: {2}' -f $done, $total, $used)
            if ($sync.Finished -and $script:SmRunning) {
                $script:SmRunning = $false
                if ($script:SmPs) {
                    try { $null = $script:SmPs.EndInvoke($script:SmHandle) } catch {}
                    $script:SmPs.Dispose(); $script:SmPs = $null
                }
                if ($script:SmRs) {
                    $script:SmRs.Close(); $script:SmRs.Dispose(); $script:SmRs = $null
                }
                (& $script:fnF 'BtnStart').IsEnabled = $true
                (& $script:fnF 'BtnStop').IsEnabled = $false
                (& $script:fnF 'TxtSource').IsEnabled = $true
                (& $script:fnF 'TxtOutput').IsEnabled = $true
                & $script:fnStopSmTimer
            }
        })
    $t.Start()
    $script:SmTimer = $t
}
function Script:Stop-SmTimer {
    if ($script:SmTimer) { $script:SmTimer.Stop(); $script:SmTimer = $null }
}

# ============================================================
#                       XAML UI
# ============================================================
$xaml = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="White">
    <!-- 单行布局: 整页可滚动,日志走主窗口 OutputLog(独立模式走 _logs/*.log) -->
    <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <ScrollViewer VerticalScrollBarVisibility="Auto"
                  HorizontalScrollBarVisibility="Disabled">
    <Grid>
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Margin="20,15,20,5">
        <TextBlock Text="🎬 图片轮播" FontSize="20" FontWeight="Bold" Foreground="#333"/>
        <TextBlock Text="把指定目录的图片拼接成 mp4,可选过渡/切片/背景音乐" FontSize="12" Foreground="#888" Margin="0,3,0,0"/>
    </StackPanel>

    <Border Grid.Row="1" Background="#FAFAFA" CornerRadius="6" Padding="15" Margin="20,5,20,8">
        <Grid>
            <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
            <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="源目录:" VerticalAlignment="Center" Foreground="#555"/>
                <TextBox x:Name="TxtSource" Grid.Column="1" Height="28" Padding="5,0" FontSize="12"/>
                <Button x:Name="BtnBrowseSrc" Grid.Column="2" Content="..." Width="28" Height="28" Margin="5,0,0,0"/>
            </Grid>
            <Grid Margin="0,0,0,8" Grid.Row="1">
                <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="输出目录:" VerticalAlignment="Center" Foreground="#555"/>
                <TextBox x:Name="TxtOutput" Grid.Column="1" Height="28" Padding="5,0" FontSize="12"/>
                <Button x:Name="BtnBrowseOut" Grid.Column="2" Content="..." Width="28" Height="28" Margin="5,0,0,0"/>
            </Grid>
            <Grid Grid.Row="2">
                <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="输出文件名:" VerticalAlignment="Center" Foreground="#555"/>
                <TextBox x:Name="TxtOutBase" Grid.Column="1" Height="28" Padding="5,0" FontSize="12" Text="slideshow"/>
                <TextBlock Grid.Column="2" Text=".mp4" VerticalAlignment="Center" Foreground="#888" Margin="5,0,0,0"/>
            </Grid>
        </Grid>
    </Border>

    <Border Grid.Row="2" Background="#FAFAFA" CornerRadius="6" Padding="15" Margin="20,0,20,8">
        <StackPanel>
            <TextBlock Text="📂 排序与图片类型" FontWeight="SemiBold" Foreground="#555" Margin="0,0,0,6"/>
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Margin="0,0,8,0">
                    <TextBlock Text="排序:" FontSize="11" Foreground="#666"/>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <ComboBox x:Name="CmbSort" Grid.Column="0" Height="26" FontSize="12" SelectedIndex="0">
                            <ComboBoxItem Content="文件名"/><ComboBoxItem Content="修改日期"/>
                        </ComboBox>
                        <ComboBox x:Name="CmbOrder" Grid.Column="1" Height="26" FontSize="12" SelectedIndex="0" Margin="5,0,0,0">
                            <ComboBoxItem Content="升序"/><ComboBoxItem Content="降序"/>
                        </ComboBox>
                    </Grid>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="8,0,0,0">
                    <TextBlock Text="图片类型:" FontSize="11" Foreground="#666"/>
                    <StackPanel Orientation="Horizontal">
                        <CheckBox x:Name="ChkJpg" Content="jpg" IsChecked="True" Margin="0,0,8,0"/>
                        <CheckBox x:Name="ChkPng" Content="png" IsChecked="True" Margin="0,0,8,0"/>
                        <CheckBox x:Name="ChkBmp" Content="bmp" Margin="0,0,8,0"/>
                        <CheckBox x:Name="ChkWebp" Content="webp"/>
                    </StackPanel>
                </StackPanel>
            </Grid>
            <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="120"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Margin="0,0,8,0">
                    <TextBlock Text="缩放模式:" FontSize="11" Foreground="#666"/>
                    <ComboBox x:Name="CmbScale" Height="26" FontSize="12" SelectedIndex="0">
                        <ComboBoxItem Content="居中 (contain, 留黑边)"/>
                        <ComboBoxItem Content="裁剪 (crop, 填满)"/>
                        <ComboBoxItem Content="模糊背景 (blur_bg)"/>
                    </ComboBox>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="8,0,0,0">
                    <TextBlock Text="背景色 (填充):" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtBgColor" Height="26" Padding="5,0" FontSize="12" Text="black"/>
                </StackPanel>
            </Grid>
        </StackPanel>
    </Border>

    <Border Grid.Row="3" Background="#FAFAFA" CornerRadius="6" Padding="15" Margin="20,0,20,8">
        <StackPanel>
            <TextBlock Text="🎞 视频参数" FontWeight="SemiBold" Foreground="#555" Margin="0,0,0,6"/>
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Margin="0,0,8,0">
                    <TextBlock Text="分辨率:" FontSize="11" Foreground="#666"/>
                    <ComboBox x:Name="CmbRes" Height="26" FontSize="12" SelectedIndex="1">
                        <ComboBoxItem Content="原图 (按第一张)"/>
                        <ComboBoxItem Content="1920x1080"/>
                        <ComboBoxItem Content="2560x1440"/>
                        <ComboBoxItem Content="3840x2160"/>
                        <ComboBoxItem Content="1280x720"/>
                    </ComboBox>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="0,0,8,0">
                    <TextBlock Text="帧率 FPS:" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtFps" Height="26" Padding="5,0" FontSize="12" Text="30"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Margin="0,0,8,0">
                    <TextBlock Text="码率 (M):" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtBitrate" Height="26" Padding="5,0" FontSize="12" Text="5"/>
                </StackPanel>
                <StackPanel Grid.Column="3">
                    <TextBlock Text="编码:" FontSize="11" Foreground="#666"/>
                    <ComboBox x:Name="CmbCodec" Height="26" FontSize="12" SelectedIndex="0">
                        <ComboBoxItem Content="libx264"/><ComboBoxItem Content="libx265"/>
                    </ComboBox>
                </StackPanel>
            </Grid>
        </StackPanel>
    </Border>

    <Border Grid.Row="4" Background="#FAFAFA" CornerRadius="6" Padding="15" Margin="20,0,20,8">
        <StackPanel>
            <TextBlock Text="⏱ 内容参数" FontWeight="SemiBold" Foreground="#555" Margin="0,0,0,6"/>
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Margin="0,0,8,0">
                    <TextBlock Text="每图时长 (秒):" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtImgDur" Height="26" Padding="5,0" FontSize="12" Text="3"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="0,0,8,0">
                    <TextBlock Text="效果 (Tools/ffmpeg-video-slideshow-scripts/):" FontSize="11" Foreground="#666"/>
                    <ComboBox x:Name="CmbEffect" Height="26" FontSize="12" SelectedIndex="0"/>
                </StackPanel>
                <StackPanel Grid.Column="2" Margin="0,0,8,0">
                    <TextBlock Text="过渡时长 (秒):" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtTransDur" Height="26" Padding="5,0" FontSize="12" Text="1"/>
                </StackPanel>
                <StackPanel Grid.Column="3">
                    <TextBlock Text="每段图片数 (0=不切):" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtSplitN" Height="26" Padding="5,0" FontSize="12" Text="50"/>
                </StackPanel>
            </Grid>
        </StackPanel>
    </Border>

    <!-- 高级: Ken Burns + 胶片黑边 + 水印 -->
    <Border Grid.Row="5" Background="#FAFAFA" CornerRadius="6" Padding="15" Margin="20,0,20,8">
        <StackPanel>
            <TextBlock Text="🎥 高级效果" FontWeight="SemiBold" Foreground="#555" Margin="0,0,0,6"/>
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Margin="0,0,8,0">
                    <TextBlock Text="Ken Burns (图内推拉):" FontSize="11" Foreground="#666"/>
                    <ComboBox x:Name="CmbKb" Height="26" FontSize="12" SelectedIndex="0">
                        <ComboBoxItem Content="无"/>
                        <ComboBoxItem Content="缓慢放大 zoom_in"/>
                        <ComboBoxItem Content="缓慢缩小 zoom_out"/>
                        <ComboBoxItem Content="左→右 pan_left"/>
                        <ComboBoxItem Content="右→左 pan_right"/>
                        <ComboBoxItem Content="上→下 pan_down"/>
                        <ComboBoxItem Content="下→上 pan_up"/>
                    </ComboBox>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="0,0,8,0">
                    <TextBlock Text="胶片黑边 (上下):" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtLetterbox" Height="26" Padding="5,0" FontSize="12" Text="0"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                    <TextBlock Text="每张图播放:" FontSize="11" Foreground="#666"/>
                    <TextBlock FontSize="11" Foreground="#888" Text="每图时长由上方控制"/>
                </StackPanel>
            </Grid>
            <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="120"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions>
                <TextBlock Text="水印 (PNG):" VerticalAlignment="Center" Foreground="#555"/>
                <TextBox x:Name="TxtWatermark" Grid.Column="1" Height="28" Padding="5,0" FontSize="12"/>
                <Button x:Name="BtnBrowseWm" Grid.Column="2" Content="..." Width="28" Height="28" Margin="5,0,0,0"/>
                <ComboBox x:Name="CmbWmPos" Grid.Column="3" Height="28" FontSize="12" Margin="8,0,0,0">
                    <ComboBoxItem Content="右下角"/>
                    <ComboBoxItem Content="左上角"/>
                    <ComboBoxItem Content="右上角"/>
                    <ComboBoxItem Content="左下角"/>
                </ComboBox>
                <TextBox x:Name="TxtWmOpacity" Grid.Column="4" Height="28" Padding="5,0" FontSize="12" Margin="8,0,0,0" Text="1.0"/>
            </Grid>
        </StackPanel>
    </Border>

    <Border Grid.Row="6" Background="#FAFAFA" CornerRadius="6" Padding="15" Margin="20,0,20,8">
        <StackPanel>
            <TextBlock Text="🎵 背景音乐 (可选)" FontWeight="SemiBold" Foreground="#555" Margin="0,0,0,6"/>
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="100"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions>
                <TextBox x:Name="TxtBgm" Grid.Column="0" Height="28" Padding="5,0" FontSize="12"/>
                <Button x:Name="BtnBrowseBgm" Grid.Column="1" Content="..." Width="28" Height="28" Margin="5,0,0,0"/>
                <StackPanel Grid.Column="2" Margin="8,0,0,0">
                    <TextBlock Text="淡入 (秒):" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtFadeIn" Height="26" Padding="5,0" FontSize="12" Text="0"/>
                </StackPanel>
                <StackPanel Grid.Column="3" Margin="8,0,0,0">
                    <TextBlock Text="淡出 (秒):" FontSize="11" Foreground="#666"/>
                    <TextBox x:Name="TxtFadeOut" Height="26" Padding="5,0" FontSize="12" Text="0"/>
                </StackPanel>
            </Grid>
        </StackPanel>
    </Border>

    <Border Grid.Row="7" Background="#FAFAFA" CornerRadius="6" Padding="15" Margin="20,0,20,8">
        <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" VerticalAlignment="Center">
                <TextBlock Text="拼接模式:" FontSize="11" Foreground="#666"/>
                <ComboBox x:Name="CmbConcatMode" Height="26" FontSize="12" SelectedIndex="0">
                    <ComboBoxItem Content="简单拼接 (concat, 稳定)"/>
                    <ComboBoxItem Content="filter_complex (过渡)"/>
                </ComboBox>
                <CheckBox x:Name="ChkTmp" Content="在源目录创建临时副本 (001.jpg,002.jpg...)" Margin="0,8,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <Button x:Name="BtnScan" Content="🔍 扫描清单" Width="100" Height="34" Margin="5,0"
                        Background="#E0E0E0" Foreground="#333" BorderThickness="0" Cursor="Hand"/>
                <Button x:Name="BtnStart" Content="▶ 生成视频" Width="110" Height="34" Margin="5,0"
                        Background="#0078D4" Foreground="White" FontWeight="SemiBold" BorderThickness="0" Cursor="Hand"/>
                <Button x:Name="BtnStop" Content="⏹ 停止" Width="90" Height="34" Margin="5,0"
                        Background="#A52A2A" Foreground="White" BorderThickness="0" Cursor="Hand" IsEnabled="False"/>
                <Button x:Name="BtnOpenOut" Content="📁" Width="34" Height="34" Margin="5,0"
                        Background="#E0E0E0" Foreground="#333" BorderThickness="0" Cursor="Hand"/>
            </StackPanel>
        </Grid>
    </Border>

    <Border Grid.Row="8" Background="#FFFEF8" CornerRadius="6" Padding="15" Margin="20,0,20,8"
            BorderBrush="#E0D8B0" BorderThickness="1">
        <StackPanel>
            <TextBlock x:Name="TxtStatus" Text="空闲" FontSize="14" Foreground="#333" Margin="0,0,0,6"/>
            <ProgressBar x:Name="PrgProgress" Height="18" Minimum="0" Maximum="100" Value="0" Background="#EEE" Foreground="#0078D4"/>
            <TextBlock x:Name="TxtStats" Text="段: 0/0 | 已用: --:--"
                       FontSize="11" Foreground="#666" Margin="0,8,0,0" FontFamily="Consolas"/>
        </StackPanel>
    </Border>
    </Grid>
    </ScrollViewer>
</Grid>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)
$script:SmUi = $ui

# 一次性缓存所有命名控件,避免 click handler 闭包里的 FindName 作用域问题
$script:SmEls = @{}
$elsNames = @(
    'TxtSource', 'TxtOutput', 'TxtOutBase', 'BtnBrowseSrc', 'BtnBrowseOut',
    'BtnBrowseBgm', 'BtnBrowseWm', 'BtnScan', 'BtnStart', 'BtnStop', 'BtnOpenOut',
    'CmbSort', 'CmbOrder', 'CmbScale', 'TxtBgColor',
    'CmbRes', 'TxtFps', 'TxtBitrate', 'CmbCodec',
    'TxtImgDur', 'CmbEffect', 'TxtTransDur', 'TxtSplitN',
    'CmbKb', 'TxtLetterbox', 'TxtWatermark', 'CmbWmPos', 'TxtWmOpacity',
    'TxtBgm', 'TxtFadeIn', 'TxtFadeOut', 'CmbConcatMode', 'ChkTmp',
    'ChkJpg', 'ChkPng', 'ChkBmp', 'ChkWebp',
    'TxtStatus', 'PrgProgress', 'TxtStats'
)
foreach ($n in $elsNames) { $script:SmEls[$n] = $ui.FindName($n) }

# 简化访问
function F($name) { return $script:SmEls[$name] }

# 扫描 Tools/ffmpeg-video-slideshow-scripts/ 下的所有 .ps1 效果脚本
function Get-SmEffects {
    $root = Join-Path $Global:GeminiToolsDir 'ffmpeg-video-slideshow-scripts'
    $list = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $root)) { return , $list.ToArray() }
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' |
    Where-Object { $_.Name -notmatch '^_' -and $_.DirectoryName -notmatch '_lib$' } |
    ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1)
        $cat = Split-Path $rel -Parent
        $list.Add([PSCustomObject]@{
                Name        = $_.BaseName
                Path        = $_.FullName
                Category    = $cat
                DisplayName = "$cat/$($_.BaseName)"
            })
    }
    return , $list.ToArray()
}

# ====== 函数 → scriptblock → $script:fnX (供 click handler 持久调用,跨 dot-source 作用域) ======
# 参考 audioVedioTools.ps1 的标准模式:函数定义后注册为 $script: 变量,
# click handler 用 & $script:fnX 调用,绕过 Set-Tool 函数作用域销毁问题
# ⚠️ 必须在 Get-SmEffects / CmbEffect 填充之前执行,否则 $script:fnF 是 $null,触发 "& 后面表达式无效" 错误
$script:fnF = (Get-Command F).ScriptBlock
$script:fnScanSmImages = (Get-Command Scan-SmImages).ScriptBlock
$script:fnWriteSmLog = (Get-Command Write-SmLog).ScriptBlock
$script:fnStartSmRun = (Get-Command Start-SmRun).ScriptBlock
$script:fnStopSmRun = (Get-Command Stop-SmRun).ScriptBlock
$script:fnStartSmTimer = (Get-Command Start-SmTimer).ScriptBlock
$script:fnStopSmTimer = (Get-Command Stop-SmTimer).ScriptBlock

# 填充 CmbEffect
$script:SmEffects = Get-SmEffects
$effectCmb = (& $script:fnF 'CmbEffect')
$effectCmb.Items.Clear()
foreach ($e in $script:SmEffects) {
    [void]$effectCmb.Items.Add($e.DisplayName)
}
if ($script:SmEffects.Count -gt 0) { $effectCmb.SelectedIndex = 0 }
Write-SmLog ("Found {0} effect scripts" -f $script:SmEffects.Count) Success

(& $script:fnF 'BtnBrowseSrc').Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "选择图片源目录"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $sp = $dlg.SelectedPath
            if ($sp) {
                (& $script:fnF 'TxtSource').Text = $sp
                if (-not (& $script:fnF 'TxtOutput').Text) { (& $script:fnF 'TxtOutput').Text = $sp }
            }
        }
    })
(& $script:fnF 'BtnBrowseOut').Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "选择视频输出目录"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $sp = $dlg.SelectedPath
            if ($sp) { (& $script:fnF 'TxtOutput').Text = $sp }
        }
    })
(& $script:fnF 'BtnBrowseBgm').Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "音频 (*.mp3;*.wav;*.m4a;*.aac)|*.mp3;*.wav;*.m4a;*.aac|所有文件|*.*"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            (& $script:fnF 'TxtBgm').Text = $dlg.FileName
        }
    })
(& $script:fnF 'BtnBrowseWm').Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = "图片 (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg|所有文件|*.*"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            (& $script:fnF 'TxtWatermark').Text = $dlg.FileName
        }
    })
(& $script:fnF 'BtnScan').Add_Click({
        $src = (& $script:fnF 'TxtSource').Text.Trim()
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { & $script:fnWriteSmLog "源目录无效" Error; return }
        $exts = @()
        if ((& $script:fnF 'ChkJpg').IsChecked) { $exts += 'jpg', 'jpeg' }
        if ((& $script:fnF 'ChkPng').IsChecked) { $exts += 'png' }
        if ((& $script:fnF 'ChkBmp').IsChecked) { $exts += 'bmp' }
        if ((& $script:fnF 'ChkWebp').IsChecked) { $exts += 'webp' }
        $sortField = if ((& $script:fnF 'CmbSort').Text -like '*日期*') { 'MTime' } else { 'Name' }
        $sortDir = if ((& $script:fnF 'CmbOrder').Text -like '*降*') { 'Desc' } else { 'Asc' }
        $items = & $script:fnScanSmImages $src $exts $sortField $sortDir
        & $script:fnWriteSmLog ('扫描到 {0} 张图片' -f $items.Count) Success
        if ($items.Count -gt 0) {
            & $script:fnWriteSmLog ('首图: ' + $items[0].Name) Info
            & $script:fnWriteSmLog ('末图: ' + $items[-1].Name) Info
        }
    })
(& $script:fnF 'BtnStart').Add_Click({ & $script:fnStartSmRun })
(& $script:fnF 'BtnStop').Add_Click({ & $script:fnStopSmRun })
(& $script:fnF 'BtnOpenOut').Add_Click({
        $o = (& $script:fnF 'TxtOutput').Text.Trim()
        if (-not $o) { $o = (& $script:fnF 'TxtSource').Text.Trim() }
        if ($o -and (Test-Path -LiteralPath $o)) {
            Start-Process "explorer.exe" "`"$o`""
        }
        else {
            [System.Windows.MessageBox]::Show("目录无效或不存在", "提示",
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        }
    })

if (-not $script:FfmpegOk) {
    Write-SmLog "Warning: ffmpeg.exe not found, put it under Tools\lib\ffmpeg\ or add to system PATH" Warning
}
Write-ToolLog "Slideshow Maker loaded" Success
return $ui