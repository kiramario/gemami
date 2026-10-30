# ============================================================================
# ExtremeArchive.ps1  —— 极限归档工具
# 用途: 把多个视频用 AV1 (SVT-AV1) 压到最小体积, 专用于长期归档。
#       不在乎编码耗时, 只追求压缩率。
# 依赖: ffmpeg.exe / ffprobe.exe (Tools\lib\)
#
# 档位依据(本机实测 1080p 真实动画源, CRF40, 每 5 秒片段):
#   preset 6 -> 443KB  7.23 fps   均衡
#   preset 2 -> 347KB  0.82 fps   极限(拐点)
#   preset 0 -> 351KB  0.22 fps   比 preset2 慢 3.6 倍却没变小, 无意义
#   libaom   -> 388KB  0.07 fps   反而更差且极慢, 不采用
# ============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

# ---------- 日志 ----------
# 函数名不能用 Write-Log: dot-source 时会覆盖 Main.ps1 全局同名函数导致无限递归
function Write-EaLog {
    param([string]$Message, [string]$Type = "Info")
    Write-ToolLog $Message $Type
}

if (-not (Get-Command Write-ToolLog -ErrorAction SilentlyContinue)) {
    $logDir = Join-Path $script:ScriptDir '_logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
    }
    $script:LogFile = Join-Path $logDir ('ExtremeArchive_' + (Get-Date -Format 'yyyyMMdd') + '.log')
    function Write-ToolLog {
        param([string]$Message, [string]$Type = "Info")
        $ts = Get-Date -Format 'HH:mm:ss'
        $line = "[$ts] [$Type] $Message"
        $line | Out-File -LiteralPath $script:LogFile -Append -Encoding UTF8
        Write-Host $line
    }
}

# ---------- 状态变量 ----------
$script:FFmpegPath   = $null
$script:FFprobePath  = $null
$script:SevenZipPath = $null
# 打包模式状态
$script:EncMode      = 'encode'   # encode | pack
$script:PackMode     = 0          # 0=ZIP 按文件夹分包  1=7z 单包分卷
$script:PackVolume   = 2          # 0=不分卷 1=46g 2=92g 3=117g
$script:PackGenSum   = $true
$script:PackUsePwd   = $false
$script:PackPassword = ''
$script:PackEncHeader = $true
$script:PackTasks = @(); $script:PackTotal = 0; $script:PackIdx = 0
$script:PackProc = $null; $script:PackCur = $null
$script:PackDone = 0; $script:PackSuccess = 0; $script:PackFailed = 0
$script:PackAbort = $false; $script:PackStartTime = $null
$script:PackLogTime = Get-Date
$script:VideoExts    = @('.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v', '.ts', '.m2ts', '.mpg', '.mpeg', '.3gp', '.vob')

$script:EncInputMode = 'file'
$script:EncInputPath = ''
$script:EncOutDir    = ''
$script:EncTier      = 2        # 默认 极限(preset2)
$script:EncCRF       = 40
$script:EncRes       = 0        # 0=原分辨率
$script:EncDepth     = 10
$script:EncACodec    = 'opus64'
$script:EncContainer = 0        # 0=MKV
$script:EncAllAudio  = $false
$script:EncAllSubs   = $false
$script:EncKeepSource = $true

$script:ArcFiles = @(); $script:ArcTotal = 0; $script:ArcIdx = 0
$script:ArcProc = $null; $script:ArcCur = $null; $script:ArcOut = ''
$script:ArcSrcSize = 0; $script:ArcCurDuration = 0
$script:ArcDone = 0; $script:ArcSuccess = 0; $script:ArcFailed = 0
$script:ArcSaved = [double]0; $script:ArcAbort = $false
$script:ArcProgressFile = ''; $script:ArcPct = 0
$script:ArcLoggedPct = -100; $script:ArcLogTime = Get-Date
$script:ArcFileStart = $null; $script:ArcStartTime = $null
$script:ArcLastPct = 0; $script:ArcLastTime = $null; $script:ArcFps = 0

# 归档档位: Preset 为 SVT-AV1 的 0~13(越小越慢越强)
$script:ArchiveTiers = @(
    @{ Name = '① 均衡 (preset 6) · 快';       Preset = '6'; Note = '压缩率良好, 速度最快' }
    @{ Name = '② 高压缩 (preset 4) · 较慢';   Preset = '4'; Note = '比均衡再省约 10%' }
    @{ Name = '③ 极限 (preset 2) · 很慢 ★推荐'; Preset = '2'; Note = '实测最佳收益拐点, 比均衡再省 22%' }
    @{ Name = '④ 疯狂 (preset 0) · 极慢';     Preset = '0'; Note = '实测与 preset2 几乎无差, 慢 3.6 倍' }
)

# ---------- 工具函数 ----------
function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Format-Time {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $s = [int][math]::Round($Seconds)
    $h = [int][math]::Floor($s / 3600)
    $m = [int][math]::Floor(($s % 3600) / 60)
    $sec = $s % 60
    if ($h -gt 0) { return ('{0}:{1:D2}:{2:D2}' -f $h, $m, $sec) }
    return ('{0:D2}:{1:D2}' -f $m, $sec)
}

function Invoke-OnUiThread {
    param([ScriptBlock]$ScriptBlock, [object[]]$ArgumentList = @())
    if ($null -eq $script:ui -or $script:ui.Dispatcher.CheckAccess()) {
        & $ScriptBlock @ArgumentList
    }
    else {
        $payload = [pscustomobject]@{ Sb = $ScriptBlock; Args = $ArgumentList }
        $script:ui.Dispatcher.Invoke([System.Action]{
                param($p)
                & $p.Sb @($p.Args)
            }, [object[]]@($payload)
        ) | Out-Null
    }
}

function Append-EaLogLine {
    param([string]$Text, [string]$Color)
    $action = {
        param($t, $c)
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $t
        $item.Foreground = $c
        [void]$script:lstLog.Items.Add($item)
        $script:lstLog.ScrollIntoView($item)
    }
    & $script:fnInvokeOnUi $action -ArgumentList @($Text, $Color)
}

function Add-EaLog {
    param([string]$Message, [string]$Type = "Info")
    $ts = Get-Date -Format 'HH:mm:ss'
    $tag = switch ($Type) { "Info" { "INFO" } "Warning" { "WARN" } "Error" { "ERR " } "Success" { " OK " } default { "INFO" } }
    $color = switch ($Type) { "Error" { "#FF6B6B" } "Warning" { "#FFD93D" } "Success" { "#6BCB77" } default { "#D0D0D0" } }
    try { & $script:fnWriteLog $Message -Type $Type } catch { }
    try { & $script:fnAppendLog ("[$ts] [$tag] $Message") $color } catch { }
}

function Update-EaProgress {
    param([int]$Done, [int]$Total, [int]$FilePct = -1)
    $action = {
        param($d, $t, $fp)
        if ($t -le 0) { $script:prgBar.Value = 0; $script:txtProgress.Text = "就绪" }
        else {
            $script:prgBar.Value = [int](($d / $t) * 100)
            if ($fp -ge 0) { $script:txtProgress.Text = "$d / $t ($($script:prgBar.Value)%) · 当前 $fp%" }
            else { $script:txtProgress.Text = "$d / $t ($($script:prgBar.Value)%)" }
        }
    }
    & $script:fnInvokeOnUi $action -ArgumentList @($Done, $Total, $FilePct)
}

function Find-FFmpeg {
    $p = Join-Path $script:ScriptDir 'lib\ffmpeg.exe'
    if (Test-Path -LiteralPath $p) { $script:FFmpegPath = $p }
    $q = Join-Path $script:ScriptDir 'lib\ffprobe.exe'
    if (Test-Path -LiteralPath $q) { $script:FFprobePath = $q }
}

# 查找 7z.exe (打包模式需要)
function Find-7z {
    $candidates = @(
        'E:\portable\PortableApps\7-ZipPortable\App\7-Zip\7z.exe',
        'E:\portable\PortableApps\7-ZipPortable\7z.exe',
        (Join-Path $script:ScriptDir 'lib\7z.exe'),
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        (Join-Path $env:LOCALAPPDATA 'Programs\7-Zip\7z.exe')
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
            $script:SevenZipPath = $c
            return $c
        }
    }
    return $null
}

function Get-VideoInfo {
    param([string]$Path)
    $info = @{ Path = $Path; Name = ''; SizeBytes = 0; DurationSec = 0; DurationStr = '00:00:00'; Width = 0; Height = 0; VCodec = '未知'; Depth = '未知' }
    $fi = Get-Item -LiteralPath $Path
    $info.Name = $fi.Name
    $info.SizeBytes = $fi.Length

    if ($script:FFprobePath) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:FFprobePath
            $psi.Arguments = '-v quiet -print_format json -show_streams -show_format "' + $Path + '"'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $json = $p.StandardOutput.ReadToEnd()
            [void]$p.StandardError.ReadToEnd()
            $p.WaitForExit()
            if ($p.ExitCode -eq 0 -and $json) {
                $d = $json | ConvertFrom-Json
                if ($d.format -and $d.format.duration) { $info.DurationSec = [double]$d.format.duration }
                $vs = $d.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
                if ($vs) {
                    if ($vs.width) { $info.Width = [int]$vs.width }
                    if ($vs.height) { $info.Height = [int]$vs.height }
                    if ($vs.codec_name) { $info.VCodec = $vs.codec_name }
                    if ($vs.pix_fmt) { $info.Depth = if ($vs.pix_fmt -match 'p10|10le') { '10bit' } else { '8bit' } }
                }
                if ($info.DurationSec -gt 0) {
                    $h = [math]::Floor($info.DurationSec / 3600)
                    $m = [math]::Floor(($info.DurationSec % 3600) / 60)
                    $s = $info.DurationSec % 60
                    $info.DurationStr = ('{0:D2}:{1:D2}:{2:D2}' -f [int]$h, [int]$m, [int][math]::Round($s))
                }
                if ($info.Width -gt 0) { return $info }
            }
        }
        catch { }
    }
    # ffmpeg 回退
    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName = $script:FFmpegPath
    $psi2.Arguments = '-i "' + $Path + '"'
    $psi2.UseShellExecute = $false
    $psi2.RedirectStandardError = $true; $psi2.RedirectStandardOutput = $true; $psi2.CreateNoWindow = $true
    $p2 = [System.Diagnostics.Process]::Start($psi2)
    $out = $p2.StandardError.ReadToEnd()
    [void]$p2.StandardOutput.ReadToEnd()
    $p2.WaitForExit()
    if ($out -match 'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)') {
        $info.DurationSec = [double]$Matches[1] * 3600 + [double]$Matches[2] * 60 + [double]$Matches[3]
    }
    if ($out -match 'Video:.*?(\d{3,5})x(\d{3,5})') { $info.Width = [int]$Matches[1]; $info.Height = [int]$Matches[2] }
    if ($info.DurationSec -gt 0) {
        $h = [math]::Floor($info.DurationSec / 3600)
        $m = [math]::Floor(($info.DurationSec % 3600) / 60)
        $s = $info.DurationSec % 60
        $info.DurationStr = ('{0:D2}:{1:D2}:{2:D2}' -f [int]$h, [int]$m, [int][math]::Round($s))
    }
    return $info
}

function Get-OutputExtension {
    $mode = $script:EncContainer
    $exts = @('.mkv', '.mp4', '.webm')
    if ($mode -ge 0 -and $mode -lt $exts.Count) { return $exts[$mode] }
    return '.mkv'
}

# 构建归档用的 ffmpeg 参数
function Get-ArchiveArgs {
    param($Info, [string]$OutPath, [string]$ProgressFile)

    $tier = $script:ArchiveTiers[$script:EncTier]
    $preset = $tier.Preset
    $crf = $script:EncCRF
    $outExt = [System.IO.Path]::GetExtension($OutPath).ToLower()

    $ffArgs = @('-y')
    if ($ProgressFile) { $ffArgs += @('-progress', "`"$ProgressFile`"") }
    $ffArgs += @('-i', "`"$($Info.Path)`"")

    $ffArgs += @('-map', '0:v:0')
    if ($script:EncAllAudio) { $ffArgs += @('-map', '0:a') }
    else { $ffArgs += @('-map', '0:a:0?') }

    # 字幕: MKV 完整保留(ASS 特效+字体), 其它容器降级
    $script:LastSubDowngraded = $false
    if ($script:EncAllSubs -and $outExt -eq '.mkv') {
        $ffArgs += @('-map', '0:s?')
        $ffArgs += @('-map', '0:t?')
    }
    elseif ($script:EncAllSubs) {
        $ffArgs += @('-map', '0:s?')
        $script:LastSubDowngraded = $true
    }

    # ---- 视频: AV1 ----
    $ffArgs += @('-c:v', 'libsvtav1')
    $ffArgs += @('-crf', $crf, '-preset', $preset)
    # tune=0 视觉质量模型 + 叠层 + 场景切换检测 (实测省 45% 的关键)
    $ffArgs += @('-svtav1-params', 'tune=0:enable-overlays=1:scd=1')
    # 极限档拉长 GOP, 进一步提升压缩率
    if ($preset -eq '2' -or $preset -eq '0') { $ffArgs += @('-g', '240') }
    $ffArgs += @('-pix_fmt', $(if ($script:EncDepth -ge 10) { 'yuv420p10le' } else { 'yuv420p' }))

    # ---- 降分辨率(归档最有效的省空间手段之一) ----
    if ($script:EncRes -gt 0) {
        $srcLong = [math]::Max($Info.Width, $Info.Height)
        if ($srcLong -gt $script:EncRes) {
            $target = $script:EncRes
            if ($target % 2 -ne 0) { $target -= 1 }
            if ($Info.Width -ge $Info.Height) { $ffArgs += @('-vf', "scale=$target`:-2:flags=lanczos") }
            else { $ffArgs += @('-vf', "scale=-2`:$target:flags=lanczos") }
        }
    }

    # ---- 音频 ----
    switch ($script:EncACodec) {
        'copy'    { $ffArgs += @('-c:a', 'copy') }
        'opus32'  { $ffArgs += @('-c:a', 'libopus', '-b:a', '32k') }
        'opus48'  { $ffArgs += @('-c:a', 'libopus', '-b:a', '48k') }
        'opus64'  { $ffArgs += @('-c:a', 'libopus', '-b:a', '64k') }
        'aac96'   { $ffArgs += @('-c:a', 'aac', '-b:a', '96k') }
        'none'    { $ffArgs += @('-an') }
        default   { $ffArgs += @('-c:a', 'libopus', '-b:a', '64k') }
    }

    if ($script:EncAllSubs -and -not $script:LastSubDowngraded -and $outExt -eq '.mkv') {
        $ffArgs += @('-c:s', 'copy', '-c:t', 'copy')
    }
    elseif ($script:EncAllSubs -and $script:LastSubDowngraded) {
        if ($outExt -eq '.webm') { $ffArgs += @('-c:s', 'webvtt') }
        else { $ffArgs += @('-c:s', 'mov_text') }
    }

    $ffArgs += "`"$OutPath`""
    return $ffArgs
}

function Resolve-FileConflict {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = Split-Path $Path -Parent
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    $i = 1
    while ($true) {
        $np = Join-Path $dir "${base}_$i$ext"
        if (-not (Test-Path -LiteralPath $np)) { return $np }
        $i++
    }
}

function Start-AsyncProcess {
    param([string]$Exe, [string]$ArgLine)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    try { $p.BeginOutputReadLine() } catch { }
    try { $p.BeginErrorReadLine() } catch { }
    return $p
}

function Read-EncodeProgress {
    param([string]$ProgressFile, [double]$DurationSec)
    if ([string]::IsNullOrWhiteSpace($ProgressFile)) { return 0 }
    if (-not (Test-Path -LiteralPath $ProgressFile)) { return 0 }
    if ($DurationSec -le 0) { return 0 }
    try {
        $lines = @(Get-Content -LiteralPath $ProgressFile -Tail 40 -Encoding UTF8 -ErrorAction Stop)
        foreach ($ln in $lines) { if ($ln -match '^progress=end') { return 100 } }
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '^out_time_us=(-?\d+)') {
                $us = [double]$Matches[1]
                if ($us -le 0) { return 0 }
                $pct = ($us / 1000000.0) / $DurationSec * 100.0
                if ($pct -gt 100) { $pct = 100 }
                if ($pct -lt 0) { $pct = 0 }
                return [int][math]::Round($pct)
            }
        }
    }
    catch { }
    return 0
}

# ---------- 状态机 ----------
function Start-Archive {
    if (-not $script:FFmpegPath) { & $script:fnAddEaLog "未找到 ffmpeg.exe" 'Error'; return }

    $files = @()
    if ($script:EncInputMode -eq 'folder') {
        $dir = $script:EncInputPath
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
            & $script:fnAddEaLog "文件夹不存在: $dir" 'Error'; return
        }
        $files = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $script:VideoExts -contains $_.Extension.ToLower() })
    }
    else {
        if ([string]::IsNullOrWhiteSpace($script:EncInputPath) -or -not (Test-Path -LiteralPath $script:EncInputPath -PathType Leaf)) {
            & $script:fnAddEaLog "文件不存在" 'Error'; return
        }
        $files = @(Get-Item -LiteralPath $script:EncInputPath)
    }

    if ($files.Count -eq 0) { & $script:fnAddEaLog "未找到视频文件" 'Warning'; return }

    # 汇总源信息
    $sumBytes = 0; $sumSec = 0
    foreach ($f in $files) {
        $i = & $script:fnGetVideoInfo -Path $f.FullName
        $sumBytes += $i.SizeBytes
        $sumSec += $i.DurationSec
    }
    & $script:fnAddEaLog ("待归档: {0} 个文件, 总大小 {1}, 总时长 {2}" -f $files.Count, (& $script:fnFormatSize $sumBytes), (& $script:fnFormatTime $sumSec)) 'Info'

    $script:ArcFiles = $files
    $script:ArcTotal = $files.Count
    $script:ArcIdx = 0
    $script:ArcProc = $null
    $script:ArcDone = 0; $script:ArcSuccess = 0; $script:ArcFailed = 0
    $script:ArcSaved = [double]0; $script:ArcAbort = $false
    $script:ArcStartTime = Get-Date

    $tier = $script:ArchiveTiers[$script:EncTier]
    & $script:fnAddEaLog ("档位: {0}  CRF={1}  分辨率={2}  色深={3}bit  音频={4}" -f $tier.Name, $script:EncCRF, $(if ($script:EncRes -gt 0) { $script:EncRes } else { '原始' }), $script:EncDepth, $script:EncACodec) 'Info'
    & $script:fnAddEaLog "========== 开始极限归档 ==========" 'Info'

    & $script:fnStepArchive
    $script:BgTimer.Start()
}

function Step-Archive {
    try {
        if ($script:ArcProc) {
            if (-not $script:ArcProc.HasExited) {
                $pct = & $script:fnReadProgress -ProgressFile $script:ArcProgressFile -DurationSec $script:ArcCurDuration
                $script:ArcPct = $pct
                & $script:fnUpdateProgress $script:ArcDone $script:ArcTotal $pct

                # 实时 fps 与 ETA(AV1 很慢, 这两个信息最关键)
                $now = Get-Date
                if ($script:ArcLastTime) {
                    $dSec = ($script:ArcCurDuration * ($pct - $script:ArcLastPct) / 100.0)
                    $dT = ($now - $script:ArcLastTime).TotalSeconds
                    if ($dT -gt 0 -and $dSec -gt 0) { $script:ArcFps = [math]::Round($dSec / $dT, 2) }
                }
                $elapsed = ($now - $script:ArcLogTime).TotalSeconds
                if (($pct - $script:ArcLoggedPct) -ge 5 -or $elapsed -ge 15) {
                    $eta = ''
                    if ($script:ArcFps -gt 0 -and $pct -lt 100) {
                        $remainSec = $script:ArcCurDuration * (100 - $pct) / 100.0
                        $eta = (" · 剩余约 {0}" -f (& $script:fnFormatTime ($remainSec / $script:ArcFps)))
                    }
                    & $script:fnAddEaLog ("  ⏳ {0}% · {1} fps{2}" -f $pct, $script:ArcFps, $eta) 'Info'
                    $script:ArcLoggedPct = $pct
                    $script:ArcLogTime = $now
                    $script:ArcLastPct = $pct
                    $script:ArcLastTime = $now
                }
                return
            }

            $code = $script:ArcProc.ExitCode
            $f = $script:ArcCur
            $outPath = $script:ArcOut
            $srcSize = $script:ArcSrcSize
            $script:ArcProc = $null
            if ($script:ArcProgressFile) {
                Remove-Item -LiteralPath $script:ArcProgressFile -Force -ErrorAction SilentlyContinue
                $script:ArcProgressFile = ''
            }

            if ($code -eq 0 -and (Test-Path -LiteralPath $outPath)) {
                $newSize = (Get-Item -LiteralPath $outPath).Length
                $saved = $srcSize - $newSize
                if ($saved -gt 0) { $script:ArcSaved += $saved }
                $pctOf = if ($srcSize -gt 0) { [math]::Round(($newSize / $srcSize) * 100) } else { 100 }
                $cost = ''
                if ($script:ArcFileStart) { $cost = (" · 耗时 {0}" -f (& $script:fnFormatTime (((Get-Date) - $script:ArcFileStart).TotalSeconds))) }
                & $script:fnAddEaLog ("  ✓ {0} -> {1} (压到 {2}%{3})" -f (& $script:fnFormatSize $srcSize), (& $script:fnFormatSize $newSize), $pctOf, $cost) 'Success'
                $script:ArcSuccess++
                if (-not $script:EncKeepSource -and $f) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    & $script:fnAddEaLog ("  已删除源文件: {0}" -f (Split-Path $f.FullName -Leaf)) 'Warning'
                }
            }
            else {
                & $script:fnAddEaLog "  ✗ 失败, ffmpeg 退出码: $code" 'Error'
                $script:ArcFailed++
            }

            $script:ArcDone++
            & $script:fnUpdateProgress $script:ArcDone $script:ArcTotal 0
        }

        if ($script:ArcAbort) {
            $script:BgTimer.Stop()
            & $script:fnAddEaLog "用户已中止" 'Warning'
            & $script:fnFinishArchive
            return
        }
        if ($script:ArcIdx -ge $script:ArcFiles.Count) {
            $script:BgTimer.Stop()
            & $script:fnFinishArchive
            return
        }

        $f = $script:ArcFiles[$script:ArcIdx]
        $script:ArcIdx++

        $info = & $script:fnGetVideoInfo -Path $f.FullName
        $srcSize = $info.SizeBytes

        $outDir = $script:EncOutDir
        if ([string]::IsNullOrWhiteSpace($outDir) -or -not (Test-Path -LiteralPath $outDir)) { $outDir = $f.DirectoryName }

        $ext = & $script:fnGetOutputExt
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $outPath = & $script:fnResolveFileConflict (Join-Path $outDir ($base + '_archived' + $ext))

        $script:ArcProgressFile = Join-Path ([IO.Path]::GetTempPath()) ("ea_prog_{0}_{1}.txt" -f $PID, $script:ArcIdx)
        Remove-Item -LiteralPath $script:ArcProgressFile -Force -ErrorAction SilentlyContinue

        & $script:fnAddEaLog ("[{0}/{1}] {2} ({3}x{4}) -> {5}" -f $script:ArcIdx, $script:ArcTotal, (Split-Path $f.FullName -Leaf), $info.Width, $info.Height, (Split-Path $outPath -Leaf)) 'Info'
        $ffArgs = & $script:fnGetArchiveArgs -Info $info -OutPath $outPath -ProgressFile $script:ArcProgressFile
        & $script:fnAddEaLog ("execute: " + ($ffArgs -join ' ')) 'Cmd'
        if ($script:LastSubDowngraded) {
            & $script:fnAddEaLog "  注意: 非 MKV 容器, ASS 字幕特效/字体将丢失" 'Warning'
        }

        $script:ArcCur = $f
        $script:ArcOut = $outPath
        $script:ArcSrcSize = $srcSize
        $script:ArcCurDuration = $info.DurationSec
        $script:ArcPct = 0
        $script:ArcLoggedPct = -100
        $script:ArcLogTime = Get-Date
        $script:ArcFileStart = Get-Date
        $script:ArcLastPct = 0
        $script:ArcLastTime = $null
        $script:ArcFps = 0

        $script:ArcProc = & $script:fnStartAsyncProc -Exe $script:FFmpegPath -ArgLine ($ffArgs -join ' ')
    }
    catch {
        & $script:fnAddEaLog "执行异常: $($_.Exception.Message)" 'Error'
        $script:BgTimer.Stop()
        & $script:fnFinishArchive
    }
}

function Finish-Archive {
    if ($script:ArcProgressFile) {
        Remove-Item -LiteralPath $script:ArcProgressFile -Force -ErrorAction SilentlyContinue
        $script:ArcProgressFile = ''
    }
    & $script:fnAddEaLog ("========== 完成: 成功 {0}, 失败 {1} ==========" -f $script:ArcSuccess, $script:ArcFailed) $(if ($script:ArcFailed -eq 0) { 'Success' } else { 'Warning' })
    if ($script:ArcSaved -gt 0) { & $script:fnAddEaLog ("累计节省: " + (& $script:fnFormatSize $script:ArcSaved)) 'Success' }
    if ($script:ArcStartTime) {
        & $script:fnAddEaLog ("总用时 " + (& $script:fnFormatTime (((Get-Date) - $script:ArcStartTime).TotalSeconds))) 'Info'
        $script:ArcStartTime = $null
    }
    $script:btnStart.IsEnabled = $true
    $script:btnStop.IsEnabled = $false
    $script:prgBar.Value = 0
    $script:txtProgress.Text = "就绪"
}

# ============================================================================
# 无损打包状态机 (ZIP / 7z, 存储模式 -mx=0, 零损失)
# ============================================================================
function Start-Pack {
    if (-not $script:SevenZipPath) {
        & $script:fnAddEaLog "未找到 7z.exe，无法打包。请安装 7-Zip 或在代码中指定路径。" 'Error'
        return
    }

    $src = $script:EncInputPath
    if ([string]::IsNullOrWhiteSpace($src)) { & $script:fnAddEaLog "请先选择文件夹" 'Warning'; return }

    $outDir = $script:EncOutDir
    if ([string]::IsNullOrWhiteSpace($outDir)) {
        if (Test-Path -LiteralPath $src -PathType Container) { $outDir = $src }
        else { $outDir = Split-Path $src -Parent }
    }
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir -ErrorAction SilentlyContinue | Out-Null
    }

    $tasks = @()
    if ($script:PackMode -eq 0) {
        # ① ZIP 按文件夹分包: 源目录下每个子目录 -> 一个 ZIP
        if (Test-Path -LiteralPath $src -PathType Container) {
            $subs = @(Get-ChildItem -LiteralPath $src -Directory | Sort-Object Name)
            if ($subs.Count -eq 0) {
                # 没有子目录: 把源目录本身打成一个包
                $tasks += [pscustomobject]@{
                    Label = (Split-Path $src -Leaf)
                    OutFile = (Join-Path $outDir ((Split-Path $src -Leaf) + '.zip'))
                    Sources = @($src)
                    Fmt = 'zip'
                }
            }
            else {
                foreach ($d in $subs) {
                    $tasks += [pscustomobject]@{
                        Label = $d.Name
                        OutFile = (Join-Path $outDir ($d.Name + '.zip'))
                        Sources = @($d.FullName)
                        Fmt = 'zip'
                    }
                }
            }
        }
        else {
            # 单文件: 打成同名 ZIP
            $base = [System.IO.Path]::GetFileNameWithoutExtension($src)
            $tasks += [pscustomobject]@{
                Label = $base
                OutFile = (Join-Path $outDir ($base + '.zip'))
                Sources = @($src)
                Fmt = 'zip'
            }
        }
    }
    else {
        # ② 7z 单包 + 分卷
        $name = if (Test-Path -LiteralPath $src -PathType Container) { Split-Path $src -Leaf } else { [System.IO.Path]::GetFileNameWithoutExtension($src) }
        $tasks += [pscustomobject]@{
            Label = $name
            OutFile = (Join-Path $outDir ($name + '.7z'))
            Sources = @($src)
            Fmt = '7z'
        }
    }

    if ($tasks.Count -eq 0) { & $script:fnAddEaLog "没有需要打包的内容" 'Warning'; return }

    $script:PackTasks = $tasks
    $script:PackTotal = $tasks.Count
    $script:PackIdx = 0
    $script:PackProc = $null
    $script:PackDone = 0; $script:PackSuccess = 0; $script:PackFailed = 0
    $script:PackAbort = $false
    $script:PackStartTime = Get-Date

    & $script:fnAddEaLog ("7z: " + $script:SevenZipPath) 'Info'
    & $script:fnAddEaLog ("打包模式: {0} · 存储模式(-mx=0) 零损失" -f $(if ($script:PackMode -eq 0) { 'ZIP 按文件夹分包' } else { '7z 单包分卷' })) 'Info'
    & $script:fnAddEaLog ("待打包: {0} 个包" -f $tasks.Count) 'Info'
    & $script:fnAddEaLog "========== 开始无损打包 ==========" 'Info'

    & $script:fnStepPack
    $script:BgTimer.Start()
}

# 构造 7z 打包参数
function Get-PackArgs {
    param($Task)
    $fmt = if ($Task.Fmt -eq '7z') { '-t7z' } else { '-tzip' }
    $a = @('a', $fmt, '-mx=0', '-bso0', '-bsp0')
    # 加密: ZIP 用 -mem=AES256 强制 AES(避免弱 ZipCrypto); 7z 默认即 AES-256
    if ($script:PackUsePwd -and $script:PackPassword -ne '') {
        if ($Task.Fmt -eq 'zip') { $a += '-mem=AES256' }
        # 密码整体加引号, 使其可含空格
        $a += ('-p"' + $script:PackPassword + '"')
        # 加密文件名(仅 7z 支持; ZIP 加 -mhe 会报错且不支持)
        if ($Task.Fmt -eq '7z' -and $script:PackEncHeader) { $a += '-mhe=on' }
    }
    # 分卷(仅 7z 单包模式; ZIP 在 7-Zip 中不支持分卷)
    if ($Task.Fmt -eq '7z' -and $script:PackVolume -gt 0) {
        $v = switch ($script:PackVolume) { 1 { '46g' } 2 { '92g' } 3 { '117g' } default { '' } }
        if ($v) { $a += @('-v' + $v) }
    }
    $a += "`"$($Task.OutFile)`""
    foreach ($s in $Task.Sources) { $a += "`"$s`"" }
    return $a
}

function Step-Pack {
    try {
        # 结算上一个进程
        if ($script:PackProc) {
            if (-not $script:PackProc.HasExited) {
                $now0 = Get-Date
                if ($script:PackStartTime) {
                    $el = [math]::Round((($now0 - $script:PackStartTime).TotalSeconds))
                    & $script:fnUpdateProgress $script:PackDone $script:PackTotal 0
                    # 定期提示仍在运行(打包大文件时用户看不到进度)
                    if (($now0 - $script:PackLogTime).TotalSeconds -ge 10) {
                        & $script:fnAddEaLog ("  ⏳ 正在打包 {0} ... 已用 {1}" -f $script:PackCur.Label, (& $script:fnFormatTime $el)) 'Info'
                        $script:PackLogTime = $now0
                    }
                }
                return
            }

            $code = $script:PackProc.ExitCode
            $task = $script:PackCur
            $script:PackProc = $null

            if ($code -eq 0) {
                # 计算产物总大小(分卷时累加所有分卷)
                $arcSize = 0
                $base = $task.OutFile
                $dir = Split-Path $base -Parent
                $leaf = Split-Path $base -Leaf
                $parts = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq $leaf -or $_.Name -like ($leaf + '.*') })
                foreach ($p in $parts) { $arcSize += $p.Length }

                $srcSize = 0
                foreach ($s in $task.Sources) {
                    if (Test-Path -LiteralPath $s -PathType Container) {
                        $srcSize += (Get-ChildItem -LiteralPath $s -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    }
                    else { $srcSize += (Get-Item -LiteralPath $s).Length }
                }
                $over = $arcSize - $srcSize
                $msg = ("  ✓ {0}: {1} -> {2} (开销 {3}, {4} 个文件)" -f $task.Label, (& $script:fnFormatSize $srcSize), (& $script:fnFormatSize $arcSize), (& $script:fnFormatSize $over), $parts.Count)
                & $script:fnAddEaLog $msg 'Success'
                $script:PackSuccess++

                if ($script:PackGenSum) {
                    try {
                        $sumFile = $task.OutFile + '.sha1.txt'
                        $lines = New-Object System.Collections.ArrayList
                        foreach ($p in $parts) {
                            $h = (Get-FileHash -LiteralPath $p.FullName -Algorithm SHA1).Hash
                            [void]$lines.Add(($h.ToLower() + '  ' + $p.Name))
                        }
                        $utf8 = New-Object System.Text.UTF8Encoding($true)
                        [System.IO.File]::WriteAllText($sumFile, ($lines -join "`r`n"), $utf8)
                        & $script:fnAddEaLog ("     校验文件: " + (Split-Path $sumFile -Leaf)) 'Info'
                    }
                    catch {
                        & $script:fnAddEaLog ("     生成校验失败: " + $_.Exception.Message) 'Warning'
                    }
                }
            }
            else {
                & $script:fnAddEaLog ("  ✗ {0} 打包失败, 7z 退出码: {1}" -f $task.Label, $code) 'Error'
                $script:PackFailed++
            }

            $script:PackDone++
            & $script:fnUpdateProgress $script:PackDone $script:PackTotal 0
        }

        if ($script:PackAbort) {
            $script:BgTimer.Stop()
            & $script:fnAddEaLog "用户已中止" 'Warning'
            & $script:fnFinishPack
            return
        }
        if ($script:PackIdx -ge $script:PackTasks.Count) {
            $script:BgTimer.Stop()
            & $script:fnFinishPack
            return
        }

        $task = $script:PackTasks[$script:PackIdx]
        $script:PackIdx++
        $script:PackCur = $task
        $script:PackLogTime = Get-Date

        $args = & $script:fnGetPackArgs -Task $task
        & $script:fnAddEaLog ("[{0}/{1}] 打包 {2} -> {3}" -f $script:PackIdx, $script:PackTotal, $task.Label, (Split-Path $task.OutFile -Leaf)) 'Info'
        # ★ 日志脱敏: 密码绝不能写进日志(日志文件是明文且会长期留存)
        $displayArgs = @($args | ForEach-Object {
            if ($_ -like '-p*') { '-p******' } else { $_ }
        })
        & $script:fnAddEaLog ("execute: `"$script:SevenZipPath`" " + ($displayArgs -join ' ')) 'Cmd'
        if ($script:PackUsePwd) { & $script:fnAddEaLog "  （已加密，密码不显示在日志中）" 'Info' }

        $script:PackProc = & $script:fnStartAsyncProc -Exe $script:SevenZipPath -ArgLine ($args -join ' ')
    }
    catch {
        & $script:fnAddEaLog "打包异常: $($_.Exception.Message)" 'Error'
        $script:BgTimer.Stop()
        & $script:fnFinishPack
    }
}

function Finish-Pack {
    & $script:fnAddEaLog ("========== 打包完成: 成功 {0}, 失败 {1} ==========" -f $script:PackSuccess, $script:PackFailed) $(if ($script:PackFailed -eq 0) { 'Success' } else { 'Warning' })
    if ($script:PackStartTime) {
        & $script:fnAddEaLog ("总用时 " + (& $script:fnFormatTime (((Get-Date) - $script:PackStartTime).TotalSeconds))) 'Info'
        $script:PackStartTime = $null
    }
    & $script:fnAddEaLog "提示: 建议定期用 7z t 校验归档完整性；重要数据请保留至少两份副本。" 'Info'
    $script:btnStart.IsEnabled = $true
    $script:btnStop.IsEnabled = $false
    $script:prgBar.Value = 0
    $script:txtProgress.Text = "就绪"
}

# 统一分派: 根据归档方式调用对应的状态机
function Step-Dispatch {
    if ($script:EncMode -eq 'pack') { & $script:fnStepPack }
    else { & $script:fnStepArchive }
}

# ============================================================================
# UI
# ============================================================================
$xaml = @'
<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              Background="#1E1E1E" Padding="16">
  <StackPanel>

    <TextBlock Text="🗄️ 极限归档" FontSize="20" FontWeight="Bold" Foreground="#4FC3F7" Margin="0,0,0,4"/>
    <TextBlock Text="两种归档方式：压缩到最小体积（有损），或无损打包便于长期存放。" Foreground="#888888" FontSize="11" Margin="0,0,0,10"/>

    <!-- 归档方式 -->
    <TextBlock Text="归档方式" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <Border Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
      <StackPanel>
        <RadioButton x:Name="RdoModeEncode" GroupName="ArcMode" IsChecked="True"
                     Content="① 视频压缩 (AV1) · 体积最小 · 有损" Foreground="#FFFFFF" Margin="0,0,0,4"/>
        <RadioButton x:Name="RdoModePack" GroupName="ArcMode"
                     Content="② 无损打包 (ZIP / 7z) · 零损失 · 仅归档不压缩" Foreground="#FFFFFF" Margin="0,0,0,4"/>
        <TextBlock x:Name="TxtModeHint" Text="压缩：把 325GB 压到约 17GB，画质有损失且不可逆。" Foreground="#888888" FontSize="11" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <!-- 输入选择 (两种归档方式共用, 不能放进 PanelEncode) -->
    <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
      <RadioButton x:Name="RdoFile" Content="📄 单个文件" GroupName="InMode" IsChecked="True" Foreground="#FFFFFF" VerticalAlignment="Center" Margin="0,0,16,0"/>
      <RadioButton x:Name="RdoFolder" Content="📁 文件夹（批量）" GroupName="InMode" Foreground="#FFFFFF" VerticalAlignment="Center"/>
    </StackPanel>
    <Grid Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="TxtInput" Grid.Column="0" Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#455A64" Padding="6" IsReadOnly="True" Text="未选择"/>
      <Button x:Name="BtnBrowseInput" Grid.Column="1" Content="选择..." Margin="6,0,0,0" Background="#37474F" Foreground="#FFFFFF" Padding="12,4" BorderThickness="0"/>
    </Grid>

    <TextBlock Text="输出目录（留空则输出到源文件同目录）" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <Grid Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="TxtOutDir" Grid.Column="0" Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#455A64" Padding="6"/>
      <Button x:Name="BtnBrowseOut" Grid.Column="1" Content="选择..." Margin="6,0,0,0" Background="#37474F" Foreground="#FFFFFF" Padding="12,4" BorderThickness="0"/>
    </Grid>

    <!-- 以下为「视频压缩」专用参数, 打包模式下隐藏 -->
    <StackPanel x:Name="PanelEncode">
    <TextBlock Text="🎯 归档档位（数字越小越慢越省）" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <Border Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
      <StackPanel>
        <ComboBox x:Name="CmbTier" SelectedIndex="2" Height="28" Width="330" Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
          <ComboBoxItem Content="① 均衡 (preset 6) · 快" Foreground="#000000"/>
          <ComboBoxItem Content="② 高压缩 (preset 4) · 较慢" Foreground="#000000"/>
          <ComboBoxItem Content="③ 极限 (preset 2) · 很慢 ★推荐" Foreground="#000000"/>
          <ComboBoxItem Content="④ 疯狂 (preset 0) · 极慢" Foreground="#000000"/>
        </ComboBox>
        <TextBlock x:Name="TxtTierHint" Text="" Foreground="#888888" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <TextBlock Text="⚙ 归档参数" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <Border Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
      <StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
          <TextBlock Text="CRF:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,4,0"/>
          <ComboBox x:Name="CmbCRF" SelectedIndex="2" Width="70" Height="26" Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="32" Foreground="#000000"/>
            <ComboBoxItem Content="36" Foreground="#000000"/>
            <ComboBoxItem Content="40" Foreground="#000000"/>
            <ComboBoxItem Content="44" Foreground="#000000"/>
            <ComboBoxItem Content="48" Foreground="#000000"/>
            <ComboBoxItem Content="52" Foreground="#000000"/>
            <ComboBoxItem Content="56" Foreground="#000000"/>
          </ComboBox>
          <TextBlock Text="分辨率:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,4,0"/>
          <ComboBox x:Name="CmbRes" SelectedIndex="0" Width="110" Height="26" Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="原分辨率" Foreground="#000000"/>
            <ComboBoxItem Content="1080p" Foreground="#000000"/>
            <ComboBoxItem Content="720p" Foreground="#000000"/>
            <ComboBoxItem Content="480p" Foreground="#000000"/>
          </ComboBox>
          <TextBlock Text="色深:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,4,0"/>
          <ComboBox x:Name="CmbDepth" SelectedIndex="1" Width="70" Height="26" Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="8bit" Foreground="#000000"/>
            <ComboBoxItem Content="10bit" Foreground="#000000"/>
          </ComboBox>
        </StackPanel>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="音频:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,4,0"/>
          <ComboBox x:Name="CmbACodec" SelectedIndex="2" Width="120" Height="26" Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="Opus 32k" Foreground="#000000"/>
            <ComboBoxItem Content="Opus 48k" Foreground="#000000"/>
            <ComboBoxItem Content="Opus 64k" Foreground="#000000"/>
            <ComboBoxItem Content="AAC 96k" Foreground="#000000"/>
            <ComboBoxItem Content="复制（无损）" Foreground="#000000"/>
            <ComboBoxItem Content="无音频" Foreground="#000000"/>
          </ComboBox>
          <TextBlock Text="容器:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,4,0"/>
          <ComboBox x:Name="CmbContainer" SelectedIndex="0" Width="150" Height="26" Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="MKV（推荐）" Foreground="#000000"/>
            <ComboBoxItem Content="MP4" Foreground="#000000"/>
            <ComboBoxItem Content="WebM" Foreground="#000000"/>
          </ComboBox>
        </StackPanel>
      </StackPanel>
    </Border>

    <TextBlock Text="🎞 保留内容" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <Border Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,8">
      <StackPanel>
        <CheckBox x:Name="ChkAllAudio" Content="保留所有音轨" IsChecked="False" Foreground="#FFFFFF" Margin="0,0,0,4"/>
        <CheckBox x:Name="ChkAllSubs" Content="保留所有字幕（MKV 可完整保留 ASS 特效与字体）" IsChecked="False" Foreground="#FFFFFF" Margin="0,0,0,4"/>
      </StackPanel>
    </Border>

    <CheckBox x:Name="ChkKeepSource" Content="保留源文件（强烈建议勾选，有损压缩不可逆）" IsChecked="True" Foreground="#FFD93D" Margin="0,0,0,10"/>
    </StackPanel>

    <!-- 打包模式面板 -->
    <StackPanel x:Name="PanelPack" Visibility="Collapsed">
      <TextBlock Text="📦 打包方式（存储模式 -mx=0，不压缩，零损失）" Foreground="#B0BEC5" Margin="0,4,0,2"/>
      <Border Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,8">
        <StackPanel>
          <ComboBox x:Name="CmbPackMode" SelectedIndex="0" Height="28" Width="420" Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="① ZIP 按文件夹分包（存硬盘/网盘，推荐）" Foreground="#000000"/>
            <ComboBoxItem Content="② 7z 单包 + 分卷（刻光盘用）" Foreground="#000000"/>
          </ComboBox>
          <StackPanel x:Name="PanelVol" Orientation="Horizontal" Margin="0,8,0,0" Visibility="Collapsed">
            <TextBlock Text="分卷大小:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,4,0"/>
            <ComboBox x:Name="CmbVolume" SelectedIndex="2" Width="180" Height="26" Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
              <ComboBoxItem Content="不分卷" Foreground="#000000"/>
              <ComboBoxItem Content="46 GiB (BD50)" Foreground="#000000"/>
              <ComboBoxItem Content="92 GiB (BD100)" Foreground="#000000"/>
              <ComboBoxItem Content="117 GiB (BD128)" Foreground="#000000"/>
            </ComboBox>
          </StackPanel>
          <TextBlock x:Name="TxtPackHint" Text="源目录下每个子文件夹打成一个 ZIP（如每季一个包）。" Foreground="#888888" FontSize="11" Margin="0,6,0,0" TextWrapping="Wrap"/>
          <CheckBox x:Name="ChkGenChecksum" Content="打包后生成校验文件 (SHA1)，便于日后核对完整性"
                    IsChecked="True" Foreground="#FFFFFF" Margin="0,8,0,0"/>

          <!-- 密码加密 -->
          <CheckBox x:Name="ChkUsePassword" Content="🔒 设置密码加密（AES-256）"
                    IsChecked="False" Foreground="#FFD93D" Margin="0,10,0,0"/>
          <StackPanel x:Name="PanelPassword" Visibility="Collapsed" Margin="0,6,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="密码:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,6,0"/>
              <PasswordBox x:Name="PwdBox" Width="150" Height="26" Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#555"/>
              <TextBlock Text="确认:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,6,0"/>
              <PasswordBox x:Name="PwdBox2" Width="150" Height="26" Background="#2D2D2D" Foreground="#FFFFFF" BorderBrush="#555"/>
            </StackPanel>
            <CheckBox x:Name="ChkEncHeader" Content="同时加密文件名（仅 7z 支持；不选则无密码也能看到文件列表）"
                      IsChecked="True" Foreground="#FFFFFF" Margin="0,6,0,0"/>
            <TextBlock x:Name="TxtPwdHint" Text="⚠️ 密码不会记录在日志中。请务必牢记——忘记密码将无法恢复数据！" Foreground="#FF6B6B" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </StackPanel>

    <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="BtnStart" Content="▶ 开始归档" Background="#2E7D32" Foreground="#FFFFFF" Padding="16,8" BorderThickness="0" FontWeight="Bold"/>
      <Button x:Name="BtnStop" Content="停止" Background="#C62828" Foreground="#FFFFFF" Padding="16,8" BorderThickness="0" Margin="10,0,0,0" IsEnabled="False"/>
      <Button x:Name="BtnClearLog" Content="清空日志" Background="#37474F" Foreground="#FFFFFF" Padding="14,8" BorderThickness="0" Margin="10,0,0,0"/>
    </StackPanel>

    <ProgressBar x:Name="PrgBar" Height="18" Minimum="0" Maximum="100" Value="0" Background="#2D2D2D" Foreground="#4FC3F7" Margin="0,0,0,4"/>
    <TextBlock x:Name="TxtProgress" Text="就绪" Foreground="#B0BEC5" Margin="0,0,0,8"/>

    <TextBlock Text="日志" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <ListBox x:Name="LstLog" Height="200" Background="#161616" Foreground="#D0D0D0" BorderBrush="#455A64" FontFamily="Consolas" ScrollViewer.VerticalScrollBarVisibility="Auto"/>
  </StackPanel>
</ScrollViewer>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)

$script:ui = $ui
$script:txtInput = $ui.FindName("TxtInput")
$script:txtOutDir = $ui.FindName("TxtOutDir")
$script:rdoFile = $ui.FindName("RdoFile")
$script:rdoFolder = $ui.FindName("RdoFolder")
$script:cmbTier = $ui.FindName("CmbTier")
$script:txtTierHint = $ui.FindName("TxtTierHint")
$script:cmbCRF = $ui.FindName("CmbCRF")
$script:cmbRes = $ui.FindName("CmbRes")
$script:cmbDepth = $ui.FindName("CmbDepth")
$script:cmbACodec = $ui.FindName("CmbACodec")
$script:cmbContainer = $ui.FindName("CmbContainer")
$script:chkAllAudio = $ui.FindName("ChkAllAudio")
$script:chkAllSubs = $ui.FindName("ChkAllSubs")
$script:chkKeepSource = $ui.FindName("ChkKeepSource")
$script:btnStart = $ui.FindName("BtnStart")
$script:btnStop = $ui.FindName("BtnStop")
$script:prgBar = $ui.FindName("PrgBar")
$script:txtProgress = $ui.FindName("TxtProgress")
$script:lstLog = $ui.FindName("LstLog")
# 归档方式与打包面板
$script:rdoModeEncode = $ui.FindName("RdoModeEncode")
$script:rdoModePack = $ui.FindName("RdoModePack")
$script:txtModeHint = $ui.FindName("TxtModeHint")
$script:panelEncode = $ui.FindName("PanelEncode")
$script:panelPack = $ui.FindName("PanelPack")
$script:cmbPackMode = $ui.FindName("CmbPackMode")
$script:cmbVolume = $ui.FindName("CmbVolume")
$script:panelVol = $ui.FindName("PanelVol")
$script:txtPackHint = $ui.FindName("TxtPackHint")
$script:chkGenChecksum = $ui.FindName("ChkGenChecksum")
$script:chkUsePassword = $ui.FindName("ChkUsePassword")
$script:panelPassword = $ui.FindName("PanelPassword")
$script:pwdBox = $ui.FindName("PwdBox")
$script:pwdBox2 = $ui.FindName("PwdBox2")
$script:chkEncHeader = $ui.FindName("ChkEncHeader")

$script:fnWriteLog = (Get-Command Write-ToolLog).ScriptBlock
$script:fnInvokeOnUi = (Get-Command Invoke-OnUiThread).ScriptBlock
$script:fnAppendLog = (Get-Command Append-EaLogLine).ScriptBlock
$script:fnAddEaLog = (Get-Command Add-EaLog).ScriptBlock
$script:fnUpdateProgress = (Get-Command Update-EaProgress).ScriptBlock
$script:fnFormatSize = (Get-Command Format-Size).ScriptBlock
$script:fnFormatTime = (Get-Command Format-Time).ScriptBlock
$script:fnGetVideoInfo = (Get-Command Get-VideoInfo).ScriptBlock
$script:fnGetOutputExt = (Get-Command Get-OutputExtension).ScriptBlock
$script:fnGetArchiveArgs = (Get-Command Get-ArchiveArgs).ScriptBlock
$script:fnResolveFileConflict = (Get-Command Resolve-FileConflict).ScriptBlock
$script:fnStartAsyncProc = (Get-Command Start-AsyncProcess).ScriptBlock
$script:fnReadProgress = (Get-Command Read-EncodeProgress).ScriptBlock
$script:fnStartArchive = (Get-Command Start-Archive).ScriptBlock
$script:fnStepArchive = (Get-Command Step-Archive).ScriptBlock
$script:fnFinishArchive = (Get-Command Finish-Archive).ScriptBlock
# 打包相关
$script:fnStartPack = (Get-Command Start-Pack).ScriptBlock
$script:fnStepPack = (Get-Command Step-Pack).ScriptBlock
$script:fnFinishPack = (Get-Command Finish-Pack).ScriptBlock
$script:fnGetPackArgs = (Get-Command Get-PackArgs).ScriptBlock
$script:fnStepDispatch = (Get-Command Step-Dispatch).ScriptBlock
$script:fnFind7z = (Get-Command Find-7z).ScriptBlock
# 注意: Test-FolderMode / Select-InputPath / Select-OutDir 定义在下方, 必须在定义之后再绑定

# 定时器: 脚本块挂在 Tag 上(CLR 属性), 避免 $script: 作用域回收后 & $null 抛 BadExpression
$script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(500)
# Tag 指向统一分派函数, 它会按当前归档方式调用编码或打包状态机
$script:BgTimer.Tag = (Get-Command Step-Dispatch).ScriptBlock
$script:BgTimer.Add_Tick({
    $tmr = $this
    if (-not $tmr -and $args.Count -gt 0) { $tmr = $args[0] }
    if (-not $tmr) { $tmr = $script:BgTimer }
    $fn = if ($tmr) { $tmr.Tag } else { $null }
    if (-not $fn) { $fn = $script:fnStepDispatch }
    if ($fn) { & $fn }
})

Find-FFmpeg
if ($script:FFmpegPath) { & $script:fnAddEaLog "ffmpeg: $script:FFmpegPath" 'Success' }
else { & $script:fnAddEaLog "未找到 ffmpeg.exe，请放入 Tools\\lib 目录" 'Error' }
if ($script:FFprobePath) { & $script:fnAddEaLog "ffprobe: $script:FFprobePath" 'Success' }

function Test-FolderMode {
    $rb = $script:rdoFolder
    if (-not $rb -and $script:ui) { $rb = $script:ui.FindName("RdoFolder") }
    return [bool]($rb -and $rb.IsChecked)
}

function Select-InputPath {
    if (& $script:fnTestFolderMode) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "选择包含视频的文件夹"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return $null
    }
    else {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "选择视频文件"
        $dlg.Filter = "视频文件|*.mp4;*.mkv;*.avi;*.mov;*.flv;*.wmv;*.webm;*.m4v;*.ts;*.m2ts;*.mpg;*.mpeg;*.3gp;*.vob|所有文件|*.*"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
        return $null
    }
}

function Select-OutDir {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "选择输出目录"
    if ($script:txtOutDir.Text -and (Test-Path -LiteralPath $script:txtOutDir.Text)) { $dlg.SelectedPath = $script:txtOutDir.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

# ★ 这三个函数定义在定时器之后, 必须在此处(定义之后)绑定,
#   否则事件回调里 & $null 会抛 BadExpression
$script:fnTestFolderMode = (Get-Command Test-FolderMode).ScriptBlock
$script:fnSelectInput    = (Get-Command Select-InputPath).ScriptBlock
$script:fnSelectOutDir   = (Get-Command Select-OutDir).ScriptBlock

# ---------- 事件 ----------
$ui.FindName("BtnBrowseInput").Add_Click({
    $p = & $script:fnSelectInput
    if ($p) {
        $script:txtInput.Text = $p
        & $script:fnAddEaLog "已选择: $p" 'Info'
        if (-not (& $script:fnTestFolderMode)) {
            $i = & $script:fnGetVideoInfo -Path $p
            & $script:fnAddEaLog ("  {0}x{1} {2} {3}" -f $i.Width, $i.Height, $i.DurationStr, (& $script:fnFormatSize $i.SizeBytes)) 'Success'
        }
        else {
            $n = @(Get-ChildItem -LiteralPath $p -File | Where-Object { $script:VideoExts -contains $_.Extension.ToLower() }).Count
            & $script:fnAddEaLog "文件夹内发现 $n 个视频文件" 'Success'
        }
    }
})

$ui.FindName("BtnBrowseOut").Add_Click({
    $p = & $script:fnSelectOutDir
    if ($p) { $script:txtOutDir.Text = $p }
})

# 归档方式切换: 显示对应面板
$script:rdoModeEncode.Add_Checked({
    $script:panelEncode.Visibility = "Visible"
    $script:panelPack.Visibility = "Collapsed"
    $script:txtModeHint.Text = "压缩：把 325GB 压到约 17GB，画质有损失且不可逆。"
})
$script:rdoModePack.Add_Checked({
    $script:panelEncode.Visibility = "Collapsed"
    $script:panelPack.Visibility = "Visible"
    $script:txtModeHint.Text = "打包：存储模式(-mx=0)，内容 100% 保留，仅合并为单个/分卷文件，体积基本不变。"
    if (-not $script:SevenZipPath) { $null = & $script:fnFind7z }
    if ($script:SevenZipPath) {
        & $script:fnAddEaLog ("7z 就绪: " + $script:SevenZipPath) 'Success'
    }
    else {
        & $script:fnAddEaLog "未找到 7z.exe，打包功能不可用。请安装 7-Zip。" 'Warning'
    }
})

# 打包方式切换: 7z 单包模式才显示分卷选项
$script:cmbPackMode.Add_SelectionChanged({
    $is7z = ($script:cmbPackMode.SelectedIndex -eq 1)
    $script:panelVol.Visibility = if ($is7z) { "Visible" } else { "Collapsed" }
    if ($is7z) {
        $script:txtPackHint.Text = "全部内容打成一个 .7z 并按分卷大小切分（用于刻光盘）。注意：ZIP 格式在 7-Zip 中不支持分卷，故刻盘请用 7z。"
    }
    else {
        $script:txtPackHint.Text = "源目录下每个子文件夹打成一个 ZIP（如每季一个包）。"
    }
})

# 密码勾选: 显示/隐藏密码输入区
$script:chkUsePassword.Add_Checked({ $script:panelPassword.Visibility = "Visible" })
$script:chkUsePassword.Add_Unchecked({ $script:panelPassword.Visibility = "Collapsed" })

# 打包方式切换时: ZIP 不支持加密文件名, 隐藏该选项并提示
$script:cmbPackMode.Add_SelectionChanged({
    $is7z = ($script:cmbPackMode.SelectedIndex -eq 1)
    $script:chkEncHeader.Visibility = if ($is7z) { "Visible" } else { "Collapsed" }
    if (-not $is7z) {
        $script:chkEncHeader.IsChecked = $false
    }
    else {
        $script:chkEncHeader.IsChecked = $true
    }
})

$script:cmbTier.Add_SelectionChanged({
    $idx = $script:cmbTier.SelectedIndex
    if ($idx -ge 0 -and $idx -lt $script:ArchiveTiers.Count) {
        $script:txtTierHint.Text = $script:ArchiveTiers[$idx].Note
    }
})

$ui.FindName("BtnClearLog").Add_Click({ $script:lstLog.Items.Clear() })

$ui.FindName("BtnStop").Add_Click({
    $script:ArcAbort = $true
    if ($script:ArcProc -and -not $script:ArcProc.HasExited) { try { $script:ArcProc.Kill() } catch { } }
    $script:PackAbort = $true
    if ($script:PackProc -and -not $script:PackProc.HasExited) { try { $script:PackProc.Kill() } catch { } }
    & $script:fnAddEaLog "已请求停止，正在结束当前任务..." 'Warning'
})

$ui.FindName("BtnStart").Add_Click({
    $script:EncInputMode = if (& $script:fnTestFolderMode) { 'folder' } else { 'file' }
    $script:EncInputPath = $script:txtInput.Text.Trim()
    $script:EncOutDir = $script:txtOutDir.Text.Trim()
    $script:EncKeepSource = [bool]$script:chkKeepSource.IsChecked

    # 打包模式: 只读取打包相关设置, 然后走打包状态机
    $script:EncMode = if ($script:rdoModePack.IsChecked) { 'pack' } else { 'encode' }
    if ($script:EncMode -eq 'pack') {
        $script:PackMode = $script:cmbPackMode.SelectedIndex
        if ($script:PackMode -lt 0) { $script:PackMode = 0 }
        $script:PackVolume = $script:cmbVolume.SelectedIndex
        if ($script:PackVolume -lt 0) { $script:PackVolume = 0 }
        $script:PackGenSum = [bool]$script:chkGenChecksum.IsChecked
        $script:PackUsePwd = [bool]$script:chkUsePassword.IsChecked
        $script:PackEncHeader = [bool]$script:chkEncHeader.IsChecked

        # 密码校验: 勾选后必须输入且两次一致
        if ($script:PackUsePwd) {
            $p1 = $script:pwdBox.Password
            $p2 = $script:pwdBox2.Password
            if ([string]::IsNullOrWhiteSpace($p1)) {
                & $script:fnAddEaLog "已勾选加密但未输入密码。" 'Error'
                return
            }
            if ($p1 -ne $p2) {
                & $script:fnAddEaLog "两次输入的密码不一致。" 'Error'
                return
            }
            $script:PackPassword = $p1
        }
        else {
            $script:PackPassword = ''
        }

        if (-not $script:SevenZipPath) { $null = & $script:fnFind7z }
        if (-not $script:SevenZipPath) {
            & $script:fnAddEaLog "未找到 7z.exe，无法打包。" 'Error'
            return
        }
        if ($script:EncInputPath -eq '' -or $script:EncInputPath -eq '未选择') {
            & $script:fnAddEaLog "请先选择要打包的文件或文件夹" 'Warning'
            return
        }

        $script:btnStart.IsEnabled = $false
        $script:btnStop.IsEnabled = $true
        & $script:fnStartPack
        return
    }
    $script:EncAllAudio = [bool]$script:chkAllAudio.IsChecked
    $script:EncAllSubs = [bool]$script:chkAllSubs.IsChecked
    $script:EncTier = $script:cmbTier.SelectedIndex
    if ($script:EncTier -lt 0) { $script:EncTier = 2 }
    $script:EncCRF = [int]($script:cmbCRF.SelectedItem.Content)
    $script:EncRes = switch ($script:cmbRes.SelectedIndex) { 0 { 0 } 1 { 1920 } 2 { 1280 } 3 { 854 } default { 0 } }
    $script:EncDepth = if ($script:cmbDepth.SelectedIndex -eq 1) { 10 } else { 8 }
    $script:EncACodec = switch ($script:cmbACodec.SelectedIndex) {
        0 { 'opus32' } 1 { 'opus48' } 2 { 'opus64' } 3 { 'aac96' } 4 { 'copy' } 5 { 'none' } default { 'opus64' }
    }
    $script:EncContainer = $script:cmbContainer.SelectedIndex
    if ($script:EncContainer -lt 0) { $script:EncContainer = 0 }

    if (-not $script:FFmpegPath) { & $script:fnAddEaLog "未找到 ffmpeg.exe" 'Error'; return }
    if ($script:EncInputPath -eq '' -or $script:EncInputPath -eq '未选择') {
        & $script:fnAddEaLog "请先选择文件或文件夹" 'Warning'; return
    }

    $script:btnStart.IsEnabled = $false
    $script:btnStop.IsEnabled = $true
    & $script:fnStartArchive
})

# 初始档位提示
$script:txtTierHint.Text = $script:ArchiveTiers[2].Note

# ========== 返回或独立显示 ==========
if ($Global:MainWindow) {
    & $script:fnWriteLog "ExtremeArchive v1.0 已加载 (AV1 极限归档)" -Type Success
    return $ui
}
else {
    $window = New-Object System.Windows.Window
    $window.Title = '极限归档'
    $window.Width = 780
    $window.Height = 880
    $window.WindowStartupLocation = "CenterScreen"
    $window.Content = $ui
    $window.Background = "#1E1E1E"
    $window.ShowDialog() | Out-Null
}
