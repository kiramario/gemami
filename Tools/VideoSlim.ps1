# ============================================================================
# VideoSlim.ps1  —— 视频瘦身工具
# 功能: 读取视频信息(名称/大小/时长/音频码率体积/视频码率因子色深),
#       提供 4 组常见转换场景(含画质/兼容/体积提示, 按源分辨率屏蔽不可达场景),
#       并支持自定义音视频编码参数(编码器/CRF/色深/分辨率/音频),
#       可选择文件或文件夹批量处理, 并可决定是否保留源文件。
# 依赖: ffmpeg.exe (Tools\lib\)
# ============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

# ---------- 日志函数 ----------
# 注意: 函数名不能用 Write-Log, 否则 dot-source 加载时会覆盖 Main.ps1 的同名全局函数,
#       导致 Write-ToolLog -> Write-Log -> Write-ToolLog 无限递归 (CallDepthOverflow)。
function Write-VsLog {
    param([string]$Message, [string]$Type = "Info")
    Write-ToolLog $Message $Type
}

# 独立模式日志 fallback: 仅当未嵌入 Main.ps1 时启用
if (-not (Get-Command Write-ToolLog -ErrorAction SilentlyContinue)) {
    $logDir = Join-Path $script:ScriptDir '_logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
    }
    $script:LogFile = Join-Path $logDir ('VideoSlim_' + (Get-Date -Format 'yyyyMMdd') + '.log')
    function Write-ToolLog {
        param([string]$Message, [string]$Type = "Info")
        $ts = Get-Date -Format 'HH:mm:ss'
        $line = "[$ts] [$Type] $Message"
        $line | Out-File -LiteralPath $script:LogFile -Append -Encoding UTF8
        Write-Host $line
    }
    Write-ToolLog "VideoSlim independent mode log ready: $script:LogFile" 'Info'
}

# ---------- 脚本级变量 ----------
$script:FFmpegPath    = $null
$script:FFprobePath   = $null
$script:CurrentInfo   = $null
$script:Abort         = $false
$script:BgWorker      = $null
$script:VideoExts     = @('.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm', '.m4v', '.ts', '.mpg', '.mpeg', '.3gp')

# 由 UI 线程捕获的输入(后台线程不能直接读 WPF 控件)
$script:EncInputMode  = 'file'    # file | folder
$script:EncInputPath  = ''
$script:EncOutDir     = ''
$script:EncUseCustom  = $false
$script:EncScenario   = 0
$script:EncVCodec     = 'libx265'
$script:EncCRF        = 22
$script:EncDepth      = 8
$script:EncRes        = 0
$script:EncACodec     = 'aac192'
$script:EncPreset     = 'medium'
$script:EncKeepSource = $true
# 输出格式: 0=自动(沿用源格式) 1=mp4 2=mkv 3=mov 4=avi 5=webm
$script:EncOutFormat  = 1
# 保留内容
$script:EncAllAudio   = $false
$script:EncAllSubs    = $false
$script:EncCopyAudio  = $false
$script:SlimPct       = 0
$script:SlimProgressFile = ''
# 进度日志节流用: 上次打印的百分比 / 上次打印时间 / 本次任务开始时间
$script:SlimLoggedPct = -100
$script:SlimLogTime   = Get-Date
$script:SlimStartTime = $null

# 4 组常见转换场景
# TargetLong: 目标长边(横屏看宽/竖屏看高)
# MinSrcLong: 启用所需的最小源长边。源长边小于 TargetLong 时禁止(不做升频, 例如 1080p 源不能转 4K)。
#             场景③ 的 MinSrcLong=0 表示永远可选, 用作保底: 源不足时不放大, 仅按原分辨率重编码压缩。
$script:Scenarios = @(
    @{
        Name    = '① 4K 超清 · HEVC CRF18 10bit'
        VCodec  = 'libx265'; CRF = 18; Depth = 10; TargetLong = 3840; MinSrcLong = 3840
        Audio   = 'aac256'
        Quality = '★★★★★'; Compat = '★★☆☆☆'; Size = '★★★★★'
        SizeHint = '≈原体积 60~80%'
        Desc    = '画质最佳, 体积最大; 需设备支持 HEVC 10bit'
    },
    @{
        Name    = '② 1080p 均衡 · HEVC CRF22 8bit'
        VCodec  = 'libx265'; CRF = 22; Depth = 8; TargetLong = 1920; MinSrcLong = 1920
        Audio   = 'aac192'
        Quality = '★★★★☆'; Compat = '★★★★☆'; Size = '★★★☆☆'
        SizeHint = '≈原体积 30~45%'
        Desc    = '画质与体积平衡, 日常推荐'
    },
    @{
        Name    = '③ 720p 高压缩 · HEVC CRF26 8bit'
        VCodec  = 'libx265'; CRF = 26; Depth = 8; TargetLong = 1280; MinSrcLong = 0
        Audio   = 'aac128'
        Quality = '★★★☆☆'; Compat = '★★★★☆'; Size = '★★☆☆☆'
        SizeHint = '≈原体积 15~25%'
        Desc    = '体积最小; 源不足 720p 时保持原分辨率仅重编码'
    },
    @{
        Name    = '④ 1080p 最大兼容 · H.264 CRF23 8bit'
        VCodec  = 'libx264'; CRF = 23; Depth = 8; TargetLong = 1920; MinSrcLong = 1920
        Audio   = 'aac128'
        Quality = '★★★★☆'; Compat = '★★★★★'; Size = '★★★★☆'
        SizeHint = '≈原体积 40~60%'
        Desc    = '几乎所有设备与播放器都能放'
    }
)

# ---------- 辅助函数 ----------

function Find-FFmpeg {
    $p = Join-Path $script:ScriptDir 'lib\ffmpeg.exe'
    if (Test-Path -LiteralPath $p) { $script:FFmpegPath = $p }
    $q = Join-Path $script:ScriptDir 'lib\ffprobe.exe'
    if (Test-Path -LiteralPath $q) { $script:FFprobePath = $q }
}

# 在 UI 线程执行脚本块。
# ★ 参数用 @ArgumentList splatting 传入(调用方需写 -ArgumentList @(...))。
#   ScriptBlock 内一律用 param(...) 接收, 不依赖闭包捕获外部局部变量
#   (闭包变量在跨作用域/跨线程时会变成 $null, 导致日志等内容"消失")。
function Invoke-OnUiThread {
    param([ScriptBlock]$ScriptBlock, [object[]]$ArgumentList = @())
    if ($null -eq $script:ui -or $script:ui.Dispatcher.CheckAccess()) {
        # 已在 UI 线程: 直接执行, splatting 传参
        & $ScriptBlock @ArgumentList
    }
    else {
        # 在其他线程: 封送到 UI 线程。把 ScriptBlock 与参数作为单个对象的属性传递,
        # 避免 [System.Action] 的多参数绑定问题。
        $payload = [pscustomobject]@{ Sb = $ScriptBlock; Args = $ArgumentList }
        $script:ui.Dispatcher.Invoke([System.Action]{
                param($p)
                & $p.Sb @($p.Args)
            }, [object[]]@($payload)
        ) | Out-Null
    }
}

function Add-VsLog {
    param([string]$Message, [string]$Type = "Info")
    $ts = Get-Date -Format 'HH:mm:ss'
    $tag = switch ($Type) {
        "Info"    { "INFO" }
        "Warning" { "WARN" }
        "Error"   { "ERR " }
        "Success" { " OK " }
        default   { "INFO" }
    }
    $color = switch ($Type) {
        "Error"   { "#FF6B6B" }
        "Warning" { "#FFD93D" }
        "Success" { "#6BCB77" }
        default   { "#D0D0D0" }
    }
    # ★ 日志是从后台线程调用的, 写文件或更新 UI 都可能失败。
    #   绝不能让"记日志"这件事中断正在执行的编码任务, 因此整体容错。
    try { & $script:fnWriteLog $Message -Type $Type }
    catch {
        # 全局日志失败时回退写本工具自己的日志文件, 保证记录不丢失
        try {
            $fallback = Join-Path (Join-Path $script:ScriptDir '_logs') ('VideoSlim_' + (Get-Date -Format 'yyyyMMdd') + '.log')
            ("[$ts] [$tag] $Message") | Out-File -LiteralPath $fallback -Append -Encoding UTF8
        }
        catch { }
    }
    try {
        # ★ 必须显式传参: 若在 ScriptBlock 里直接引用外部局部变量($ts/$tag/$Message),
        #   在跨作用域/跨线程执行时这些变量会为 $null, 日志就"消失"了。
        & $script:fnAppendLog ("[$ts] [$tag] $Message") $color
    }
    catch { }
}

# 把一行日志追加到 UI 列表(统一入口, 保证作用域与线程安全)
function Append-VsLogLine {
    param([string]$Text, [string]$Color)
    $action = {
        param($t, $c)
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $t
        $item.Foreground = $c
        # Items.Add 会返回索引 int, 必须抑制
        [void]$script:lstLog.Items.Add($item)
        $script:lstLog.ScrollIntoView($item)
    }
    # ★ 必须用 -ArgumentList 传数组: 直接写 $Text $Color 会被当成多个位置参数,
    #   而第 2 个形参是 [object[]]$ArgumentList, 导致参数绑定错乱、日志静默丢失。
    & $script:fnInvokeOnUi $action -ArgumentList @($Text, $Color)
}

function Update-VsProgress {
    param([int]$Done, [int]$Total, [int]$FilePct = -1)
    $action = {
        param($d, $t, $fp)
        if ($t -le 0) { $script:prgBar.Value = 0; $script:txtProgress.Text = "就绪" }
        else {
            $script:prgBar.Value = [int](($d / $t) * 100)
            if ($fp -ge 0) {
                $script:txtProgress.Text = "$d / $t  ($($script:prgBar.Value)%)   ·   当前文件 $fp%"
            }
            else {
                $script:txtProgress.Text = "$d / $t  ($($script:prgBar.Value)%)"
            }
        }
    }
    & $script:fnInvokeOnUi $action -ArgumentList @($Done, $Total, $FilePct)
}

# 读取 ffmpeg -progress 输出的文件, 计算当前编码百分比(0-100)。
# 文件由 ffmpeg 持续追加, 可能出现共享冲突, 因此整体容错并返回上一次的值。
function Read-EncodeProgress {
    param([string]$ProgressFile, [double]$DurationSec)
    if ([string]::IsNullOrWhiteSpace($ProgressFile)) { return 0 }
    if (-not (Test-Path -LiteralPath $ProgressFile)) { return 0 }
    if ($DurationSec -le 0) { return 0 }
    try {
        # @() 强制数组化: 单行文件时 Get-Content 返回 string, $lines[0] 会取到单个字符
        $lines = @(Get-Content -LiteralPath $ProgressFile -Tail 40 -Encoding UTF8 -ErrorAction Stop)
        # 先看是否已结束
        foreach ($ln in $lines) {
            if ($ln -match '^progress=end') { return 100 }
        }
        # 取最后一个 out_time_us(微秒)。初始值可能是 int64 极小值, 需排除
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
    catch {
        # 文件被占用/不可读时忽略, 下次 tick 再试
    }
    return 0
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

# 秒数 -> 可读时长(用于进度提示, 如 1:23:45 / 12:34)
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

function Get-CodecName {
    param([string]$Raw)
    $map = @{
        'h264' = 'H.264'; 'avc1' = 'H.264'; 'hevc' = 'HEVC'; 'h265' = 'HEVC'
        'av1' = 'AV1'; 'av01' = 'AV1'; 'vp9' = 'VP9'; 'vp8' = 'VP8'
        'mpeg4' = 'MPEG-4'; 'mpeg2video' = 'MPEG-2'; 'wmv3' = 'WMV'
        'aac' = 'AAC'; 'flac' = 'FLAC'; 'mp3' = 'MP3'; 'ac3' = 'AC3'
        'eac3' = 'E-AC3'; 'dts' = 'DTS'; 'opus' = 'Opus'; 'vorbis' = 'Vorbis'
        'pcm_s16le' = 'PCM'; 'wmav2' = 'WMA'
    }
    if ($Raw -and $map.ContainsKey($Raw.ToLower())) { return $map[$Raw.ToLower()] }
    if ($Raw) { return $Raw.ToUpper() }
    return '未知'
}

function Get-BitDepth {
    param([string]$PixFmt)
    if ($PixFmt -match 'p12|12le') { return '12bit' }
    if ($PixFmt -match 'p10|10le|p010') { return '10bit' }
    return '8bit'
}

# 读取视频信息: 优先 ffprobe(JSON, 最稳最快), 没有 ffprobe 时回退 ffmpeg -i 解析
# $Ctx: 依赖注入容器(Config/Fns)。在独立 Runspace 中运行时 $script: 不可用, 必须靠它传递依赖。
function Get-VideoInfo {
    param([string]$Path, $Ctx)
    if (-not $Ctx) { $Ctx = $script:Ctx }
    $ffprobe = $Ctx.Config.FFprobePath
    $ffmpeg  = $Ctx.Config.FFmpegPath
    $fnCodec = $Ctx.Fns.GetCodecName
    $fnDepth = $Ctx.Fns.GetBitDepth
    $fnCmpl  = $Ctx.Fns.CompleteInfo

    $info = @{
        Path = $Path; Name = ''; SizeBytes = 0; DurationSec = 0; DurationStr = '00:00:00'
        VCodecRaw = ''; VCodec = '未知'; Width = 0; Height = 0; VBitrateKbps = 0; PixFmt = ''; Depth = '未知'
        ACodecRaw = ''; ACodec = '未知'; ABitrateKbps = 0; TotalBitrateKbps = 0
    }
    $fi = Get-Item -LiteralPath $Path
    $info.Name = $fi.Name
    $info.SizeBytes = $fi.Length

    # ---------- 方式一: ffprobe (JSON) ----------
    if ($ffprobe) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $ffprobe
            $psi.Arguments = '-v quiet -print_format json -show_format -show_streams -of json "' + $Path + '"'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $json = $proc.StandardOutput.ReadToEnd()
            [void]$proc.StandardError.ReadToEnd()
            $proc.WaitForExit()

            if ($proc.ExitCode -eq 0 -and $json) {
                $data = $json | ConvertFrom-Json
                if ($data.format -and $data.format.duration) {
                    $info.DurationSec = [double]$data.format.duration
                }
                if ($data.format -and $data.format.bit_rate) {
                    $info.TotalBitrateKbps = [double]$data.format.bit_rate / 1000
                }
                $vs = $data.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
                if ($vs) {
                    $info.VCodecRaw = $vs.codec_name; $info.VCodec = & $fnCodec $vs.codec_name
                    if ($vs.width)  { $info.Width  = [int]$vs.width }
                    if ($vs.height) { $info.Height = [int]$vs.height }
                    if ($vs.bit_rate) { $info.VBitrateKbps = [double]$vs.bit_rate / 1000 }
                    elseif ($vs.avg_frame_rate) { $info.VBitrateKbps = 0 }
                    if ($vs.pix_fmt) { $info.PixFmt = $vs.pix_fmt; $info.Depth = & $fnDepth $vs.pix_fmt }
                    # 视频码率缺失时用 总码率-音频码率 估算
                    if ($info.VBitrateKbps -eq 0 -and $info.TotalBitrateKbps -gt 0) {
                        $info.VBitrateKbps = $info.TotalBitrateKbps
                    }
                }
                $as = $data.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
                if ($as) {
                    $info.ACodecRaw = $as.codec_name; $info.ACodec = Get-CodecName $as.codec_name
                    if ($as.bit_rate) { $info.ABitrateKbps = [double]$as.bit_rate / 1000 }
                }
                elseif ($info.VBitrateKbps -gt 0 -and $info.TotalBitrateKbps -gt $info.VBitrateKbps) {
                    $info.ABitrateKbps = $info.TotalBitrateKbps - $info.VBitrateKbps
                }

                if ($info.DurationSec -gt 0) {
                    $h = [math]::Floor($info.DurationSec / 3600)
                    $m = [math]::Floor(($info.DurationSec % 3600) / 60)
                    $s = $info.DurationSec % 60
                    $info.DurationStr = ('{0:D2}:{1:D2}:{2:D2}' -f [int]$h, [int]$m, [int][math]::Round($s))
                }
                if ($info.Width -gt 0) { return & $fnCmpl $info }
            }
        }
        catch { }
    }

    # ---------- 方式二: 回退解析 ffmpeg -i 的 stderr ----------
    # 用 ProcessStartInfo 直接读 stderr: 避免 2>&1 在 $ErrorActionPreference='Stop' 下
    # 把 ffmpeg 的 stderr 变成终止性错误 (NativeCommandError)
    $psi2 = New-Object System.Diagnostics.ProcessStartInfo
    $psi2.FileName = $ffmpeg
    $psi2.Arguments = '-i "' + $Path + '"'
    $psi2.UseShellExecute = $false
    $psi2.RedirectStandardError = $true
    $psi2.RedirectStandardOutput = $true
    $psi2.CreateNoWindow = $true
    $proc2 = [System.Diagnostics.Process]::Start($psi2)
    $out = $proc2.StandardError.ReadToEnd()
    [void]$proc2.StandardOutput.ReadToEnd()
    $proc2.WaitForExit()

    if ($out -match 'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)') {
        $h = [double]$Matches[1]; $m = [double]$Matches[2]; $s = [double]$Matches[3]
        $info.DurationSec = $h * 3600 + $m * 60 + $s
        $info.DurationStr = ('{0:D2}:{1:D2}:{2:D2}' -f [int]$h, [int]$m, [int][math]::Round($s))
    }
    if ($out -match 'bitrate:\s*(\d+)\s*kb/s') { $info.TotalBitrateKbps = [double]$Matches[1] }

    $lines = $out -split "`r?`n"
    $vline = $lines | Where-Object { $_ -match 'Stream #.*Video:' } | Select-Object -First 1
    if ($vline) {
        if ($vline -match 'Video:\s*([a-zA-Z0-9_]+)') { $info.VCodecRaw = $Matches[1]; $info.VCodec = & $fnCodec $Matches[1] }
        if ($vline -match '(\d{3,5})x(\d{3,5})') { $info.Width = [int]$Matches[1]; $info.Height = [int]$Matches[2] }
        if ($vline -match '(\d+(?:\.\d+)?)\s*kb/s') { $info.VBitrateKbps = [double]$Matches[1] }
        if ($vline -match '(yuv[a-z0-9]+|p010[a-z0-9]*|nv12|gray[a-z0-9]*)') { $info.PixFmt = $Matches[1]; $info.Depth = & $fnDepth $Matches[1] }
    }
    $aline = $lines | Where-Object { $_ -match 'Stream #.*Audio:' } | Select-Object -First 1
    if ($aline) {
        if ($aline -match 'Audio:\s*([a-zA-Z0-9_]+)') { $info.ACodecRaw = $Matches[1]; $info.ACodec = & $fnCodec $Matches[1] }
        if ($aline -match '(\d+)\s*kb/s') { $info.ABitrateKbps = [double]$Matches[1] }
    }
    return & $fnCmpl $info
}

# 码率补全: 部分容器(MKV+FLAC 等)不存储流码率, 会读到 0。
# 此时按「文件体积 / 时长」推算总码率, 再做音视频拆分; 实在推不出的保持 0(显示为 —)。
function Complete-VideoInfo {
    param($Info)
    # 总码率缺失时按体积/时长估算
    if ($Info.TotalBitrateKbps -le 0 -and $Info.DurationSec -gt 0 -and $Info.SizeBytes -gt 0) {
        $Info.TotalBitrateKbps = ($Info.SizeBytes * 8) / $Info.DurationSec / 1000
        $Info.TotalEstimated = $true
    }
    # 视频码率缺失
    if ($Info.VBitrateKbps -le 0) {
        if ($Info.TotalBitrateKbps -gt 0 -and $Info.ABitrateKbps -gt 0) {
            $Info.VBitrateKbps = $Info.TotalBitrateKbps - $Info.ABitrateKbps
            $Info.VideoEstimated = $true
        }
        elseif ($Info.TotalBitrateKbps -gt 0) {
            $Info.VBitrateKbps = $Info.TotalBitrateKbps
            $Info.VideoEstimated = $true
        }
    }
    # 音频码率缺失: 用 总-视频 反推(仅当视频是真实值而非估算值)
    if ($Info.ABitrateKbps -le 0 -and $Info.TotalBitrateKbps -gt 0 -and $Info.VBitrateKbps -gt 0 -and -not $Info.VideoEstimated) {
        $diff = $Info.TotalBitrateKbps - $Info.VBitrateKbps
        if ($diff -gt 0 -and $diff -lt $Info.TotalBitrateKbps) {
            $Info.ABitrateKbps = $diff
            $Info.AudioEstimated = $true
        }
    }
    return $Info
}

# 按需求格式输出视频信息
function Format-VideoInfo {
    param($Info)
    $secs = [math]::Round($Info.DurationSec)
    $audioSize = ''
    if ($Info.ABitrateKbps -gt 0 -and $Info.DurationSec -gt 0) {
        $bytes = $Info.ABitrateKbps * 1000 / 8 * $Info.DurationSec
        $audioSize = ' · 约 ' + (& $script:fnFormatSize $bytes)
    }
    $lines = @()
    $lines += ('视频名称：' + $Info.Name)
    $lines += ('大小：' + (& $script:fnFormatSize $Info.SizeBytes))
    $lines += ('时长：' + $Info.DurationStr + '（' + $secs + '秒）')
    $lines += ''
    $aMark = if ($Info.AudioEstimated) { '≈' } else { '' }
    $vMark = if ($Info.VideoEstimated) { '≈' } else { '' }
    $aTxt = if ($Info.ABitrateKbps -gt 0) { $aMark + [math]::Round($Info.ABitrateKbps) + 'kbps' } else { '—' }
    $vTxt = if ($Info.VBitrateKbps -gt 0) { $vMark + [math]::Round($Info.VBitrateKbps) + 'kbps' } else { '—' }
    $lines += ("`t> 音频：" + $Info.ACodec + ' ' + $aTxt + $audioSize)
    $lines += ("`t> 视频：" + $Info.VCodec + ' ' + $vTxt + ' CRF— ' + $Info.Depth)
    $lines += ('分辨率：' + $Info.Width + 'x' + $Info.Height)
    return ($lines -join "`r`n")
}

# 根据源分辨率刷新 4 组场景的可用性
function Update-Scenarios {
    if (-not $script:CurrentInfo) { return }
    # 用长边判定(横屏取宽, 竖屏取高), 这样竖屏视频也能正确归类
    $w = [math]::Max($script:CurrentInfo.Width, $script:CurrentInfo.Height)
    for ($i = 0; $i -lt $script:Scenarios.Count; $i++) {
        $s = $script:Scenarios[$i]
        $rb = $ui.FindName('RdoS' + ($i + 1))
        $tb = $ui.FindName('TxtS' + ($i + 1))
        if (-not $rb -or -not $tb) { continue }
        $enabled = ($w -ge $s.MinSrcLong)
        $rb.IsEnabled = $enabled
        $tb.Text = ('画质{0} 兼容{1} 体积{2} · {3} · {4}' -f $s.Quality, $s.Compat, $s.Size, $s.SizeHint, $s.Desc)
        if (-not $enabled) {
            $tb.Text += '   【不可选：源分辨率不足，无法升频】'
            $tb.Foreground = '#777777'
            $rb.Foreground = '#777777'
        }
        else {
            $tb.Foreground = '#BBBBBB'
            $rb.Foreground = '#FFFFFF'
        }
    }
    # 自定义分辨率下拉：屏蔽需要升频的选项(按长边比较)
    $cmb = $script:cmbRes
    if ($cmb -and $cmb.Items.Count -ge 5) {
        $longs = @(0, 3840, 1920, 1280, 854)
        for ($k = 0; $k -lt $longs.Count; $k++) {
            $item = $cmb.Items[$k]
            if ($item -is [System.Windows.Controls.ComboBoxItem]) {
                $ok = ($longs[$k] -eq 0) -or ($w -ge $longs[$k])
                $item.IsEnabled = $ok
                if (-not $ok) { $item.Foreground = '#777777' } else { $item.Foreground = '#000000' }
            }
        }
    }
}

# 读取并展示视频信息
function Show-Info {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        & $script:fnAddVsLog "文件不存在: $Path" 'Error'
        return
    }
    & $script:fnAddVsLog "读取视频信息: $(Split-Path $Path -Leaf)" 'Info'
    try {
        $info = & $script:fnGetVideoInfo -Path $Path -Ctx $script:Ctx
        $script:CurrentInfo = $info
        $script:txtInfo.Text = & $script:fnFormatVideoInfo -Info $info
        & $script:fnUpdateScenarios
        & $script:fnAddVsLog ("  {0} · {1}x{2} · {3} · {4}" -f $info.VCodec, $info.Width, $info.Height, $info.Depth, $info.DurationStr) 'Success'
    }
    catch {
        & $script:fnAddVsLog "读取失败: $($_.Exception.Message)" 'Error'
    }
}

# 输出格式映射: 0=自动(沿用源) 1=mp4 2=mkv 3=mov 4=avi 5=webm
$script:OutFormatExts = @('', '.mp4', '.mkv', '.mov', '.avi', '.webm')

# 根据「输出格式」选择决定扩展名。自动模式沿用源文件扩展名。
function Get-OutputExtension {
    param($Info, $Ctx)
    if (-not $Ctx) { $Ctx = $script:Ctx }
    $mode = $Ctx.Config.EncOutFormat
    if ($mode -le 0) {
        # 自动: 沿用源格式; 拿不到时兜底 mp4
        $srcExt = [System.IO.Path]::GetExtension($Info.Path)
        if ([string]::IsNullOrWhiteSpace($srcExt)) { $srcExt = '.mp4' }
        return $srcExt.ToLower()
    }
    if ($mode -ge 1 -and $mode -lt $script:OutFormatExts.Count) {
        return $script:OutFormatExts[$mode]
    }
    return '.mp4'
}

# 容器与视频编码的兼容性适配。
# WebM 只支持 VP8/VP9/AV1: 搭配 H.264/HEVC(含 NVENC)会自动改用 VP9, 以免转换失败。
# 返回实际应使用的视频编码器。
function Get-CompatibleVCodec {
    param([string]$VCodec, [string]$Ext)
    if ($Ext -eq '.webm') {
        if ($VCodec -eq 'libx264' -or $VCodec -eq 'libx265') { return 'libvpx-vp9' }
        # NVENC 也无法产出 WebM, 同样回退 VP9
        if ($VCodec -eq 'hevc_nvenc' -or $VCodec -eq 'h264_nvenc') { return 'libvpx-vp9' }
        # AV1 / VP9 / copy 均可用于 webm
    }
    return $VCodec
}

# 是否为 NVENC 显卡编码器
function Test-NvencCodec {
    param([string]$VCodec)
    return ($VCodec -eq 'hevc_nvenc' -or $VCodec -eq 'h264_nvenc')
}

# 构建 ffmpeg 参数
# $Ctx: 依赖/配置容器(可能在独立 Runspace 中运行, 不能依赖 $script:)
# $ProgressFile: 若指定, 加入 -progress 让 ffmpeg 输出机器可读进度, 用于计算百分比
function Get-EncodeArgs {
    param($Info, [string]$OutPath, $Ctx, [string]$ProgressFile)
    if (-not $Ctx) { $Ctx = $script:Ctx }
    $cfg = $Ctx.Config

    $outExt = [System.IO.Path]::GetExtension($OutPath).ToLower()

    if ($cfg.EncUseCustom) {
        $vcodec = $cfg.EncVCodec
        $crf    = $cfg.EncCRF
        $depth  = $cfg.EncDepth
        $res    = $cfg.EncRes
        $audio  = $cfg.EncACodec
    }
    else {
        $s = $cfg.Scenarios[$cfg.EncScenario]
        $vcodec = $s.VCodec; $crf = $s.CRF; $depth = $s.Depth; $res = $s.TargetLong; $audio = $s.Audio
    }

    # 容器兼容性适配(如 WebM 不支持 H.264/HEVC, 自动改用 VP9)
    $vcodecUsed = & $script:fnGetCompatibleCodec -VCodec $vcodec -Ext $outExt
    $script:LastVCodec = $vcodecUsed
    $script:LastVCodecAdapted = ($vcodecUsed -ne $vcodec)
    $script:LastNvencForced8 = $false

    # 音频模式: 勾选「复制音频」时强制 copy(保住 FLAC 等无损音质)
    if ($cfg.EncCopyAudio) { $audio = 'copy' }

    $ffArgs = @('-y')
    # -progress 让 ffmpeg 输出机器可读进度(out_time_us 等), 用于实时百分比
    if ($ProgressFile) { $ffArgs += @('-progress', "`"$ProgressFile`"") }
    $ffArgs += @('-i', "`"$($Info.Path)`"")

    # ★ 流映射:
    #   默认        只取第 1 条视频 + 第 1 条音频(最小体积)
    #   保留所有音轨  0:a 全部
    #   保留所有字幕  0:s? 全部 + 0:t? 字体附件(ASS 字幕依赖附件字体)
    #   注意: 不能用 -map 0 全映射, 那会把封面(mjpeg)也带进来并被当成第 2 路视频处理。
    $ffArgs += @('-map', '0:v:0')
    if ($cfg.EncAllAudio) { $ffArgs += @('-map', '0:a') }
    else { $ffArgs += @('-map', '0:a:0?') }

    # 字幕与字体附件: 严格受容器能力限制
    #   MKV   → ASS 特效 + 字体附件 完美保留(-c:s copy -c:t copy)
    #   MP4/MOV → 只能转 mov_text, 丢失全部特效/定位/字体; 且不支持字体附件
    #   WebM  → 只能转 webvtt; 不支持附件
    #   AVI   → 基本不支持字幕流
    $script:LastSubDowngraded = $false
    $script:LastSubsSkipped   = $false
    if ($cfg.EncAllSubs) {
        if ($outExt -eq '.mkv') {
            $ffArgs += @('-map', '0:s?')
            # 字体附件: MKV 内 ASS 字幕依赖这些 TTF 才能正确显示
            $ffArgs += @('-map', '0:t?')
        }
        elseif ($outExt -eq '.mp4' -or $outExt -eq '.mov') {
            $ffArgs += @('-map', '0:s?')
            $script:LastSubDowngraded = $true
        }
        elseif ($outExt -eq '.webm') {
            $ffArgs += @('-map', '0:s?')
            $script:LastSubDowngraded = $true
        }
        else {
            # AVI 等: 跳过字幕, 避免 ffmpeg 报错
            $script:LastSubsSkipped = $true
        }
    }
    # 章节信息默认保留(ffmpeg 对 mp4/mkv 会自动复制 chapters)

    $isCopy = ($vcodecUsed -eq 'copy')
    $isNvenc = (& $script:fnTestNvenc -VCodec $vcodecUsed)
    if ($isCopy) {
        $ffArgs += @('-c:v', 'copy')
    }
    else {
        $ffArgs += @('-c:v', $vcodecUsed)
        if ($isNvenc) {
            # ★ 显卡(NVENC)参数与 CPU 软编码不同:
            #   - 不用 -crf, 而是 -rc vbr -cq N (CQ 模式, 效果类似 CRF)
            #   - -preset 用 p1~p7, 不是 fast/medium/slow
            #   - 强制 8bit: GTX 960 等旧卡不支持 10bit HEVC 硬编码(实测直接报错)
            $nvPreset = switch ($cfg.EncPreset) {
                'fast'  { 'p2' }
                'slow'  { 'p7' }
                default { 'p4' }
            }
            $ffArgs += @('-preset', $nvPreset, '-rc', 'vbr', '-cq', $crf)
            $ffArgs += @('-pix_fmt', 'yuv420p')
            if ($depth -ge 10) { $script:LastNvencForced8 = $true }
        }
        elseif ($vcodecUsed -eq 'libsvtav1') {
            # ★ AV1 调优(实测: 默认 preset 8 无 tune 时比 x265 只小 15%, 调优后可小 45~69%)
            #   - preset: SVT-AV1 的 0~13, 数字越小越慢越强。归档用 3~6
            #   - tune=0 : 视觉质量(VQ)模型, 对归档关键(默认是 PSNR 导向, 同码率观感更差)
            #   - enable-overlays / scd: 启用叠层与场景切换检测, 提升压缩率
            $svtPreset = switch ($cfg.EncPreset) {
                'fast'   { '6' }
                'medium' { '5' }
                'slow'   { '3' }
                default  { '5' }
            }
            $ffArgs += @('-crf', $crf, '-preset', $svtPreset)
            $ffArgs += @('-svtav1-params', 'tune=0:enable-overlays=1:scd=1')
            if ($depth -ge 10) { $ffArgs += @('-pix_fmt', 'yuv420p10le') }
            else { $ffArgs += @('-pix_fmt', 'yuv420p') }
        }
        elseif ($vcodecUsed -eq 'libvpx-vp9') {
            # VP9 用 -crf + -b:v 0(恒定质量模式)
            $ffArgs += @('-crf', $crf, '-b:v', '0')
            if ($depth -ge 10) { $ffArgs += @('-pix_fmt', 'yuv420p10le') }
            else { $ffArgs += @('-pix_fmt', 'yuv420p') }
        }
        else {
            $ffArgs += @('-crf', $crf, '-preset', $cfg.EncPreset)
            if ($depth -ge 10) { $ffArgs += @('-pix_fmt', 'yuv420p10le') }
            else { $ffArgs += @('-pix_fmt', 'yuv420p') }
        }

        # 缩放：只降不升。按长边比较，横屏锁宽、竖屏锁高，尺寸取偶
        if ($res -gt 0) {
            $srcLong = [math]::Max($Info.Width, $Info.Height)
            $target = [math]::Min($res, $srcLong)
            if ($target % 2 -ne 0) { $target -= 1 }
            if ($Info.Width -ge $Info.Height) {
                if ($target -lt $Info.Width) { $ffArgs += @('-vf', "scale=$target`:-2") }
            }
            else {
                if ($target -lt $Info.Height) { $ffArgs += @('-vf', "scale=-2`:$target") }
            }
        }
    }

    switch ($audio) {
        'copy'   { $ffArgs += @('-c:a', 'copy') }
        'aac128' { $ffArgs += @('-c:a', 'aac', '-b:a', '128k') }
        'aac192' { $ffArgs += @('-c:a', 'aac', '-b:a', '192k') }
        'aac256' { $ffArgs += @('-c:a', 'aac', '-b:a', '256k') }
        'mp3192' { $ffArgs += @('-c:a', 'libmp3lame', '-b:a', '192k') }
        'none'   { $ffArgs += @('-an') }
        default  { $ffArgs += @('-c:a', 'aac', '-b:a', '192k') }
    }

    # 字幕/附件编码器(仅在勾选保留字幕时才有对应映射)
    if ($cfg.EncAllSubs -and -not $script:LastSubsSkipped) {
        if ($outExt -eq '.mkv') {
            # 原样复制: ASS 特效与字体附件完整保留
            $ffArgs += @('-c:s', 'copy', '-c:t', 'copy')
        }
        elseif ($outExt -eq '.mp4' -or $outExt -eq '.mov') {
            # 转成 mov_text: 特效/定位/字体全部丢失, 仅保留纯文本
            $ffArgs += @('-c:s', 'mov_text')
        }
        elseif ($outExt -eq '.webm') {
            $ffArgs += @('-c:s', 'webvtt')
        }
    }

    if ($OutPath.ToLower().EndsWith('.mp4')) { $ffArgs += @('-movflags', '+faststart') }
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
        $newPath = Join-Path $dir "${base}_$i$ext"
        if (-not (Test-Path -LiteralPath $newPath)) { return $newPath }
        $i++
    }
}

# 启动外部进程但不阻塞; 异步排空 stdout/stderr, 避免管道缓冲区填满导致子进程卡死
function Start-AsyncProcess {
    param([string]$Exe, [string]$ArgLine)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.Arguments              = $ArgLine
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    # 无订阅者的异步读取: 数据被读出后直接丢弃, 仅用于防止缓冲区阻塞
    try { $p.BeginOutputReadLine() } catch { }
    try { $p.BeginErrorReadLine() } catch { }
    return $p
}

# ---------- 核心: 批量瘦身 ----------
# ★ 架构说明(重要):
#   不使用 BackgroundWorker / 独立 Runspace, 全部在【UI 线程】上运行, 由 DispatcherTimer 推进状态机。
#   原因:
#   1) BackgroundWorker 的线程池线程没有默认 Runspace, 调用 ScriptBlock 会直接抛
#      "此线程中没有可用于运行脚本的运行空间"。
#   2) 跨 Runspace 调用脚本函数存在会话状态冲突, 实测会偶发破坏主运行空间(cmdlet 全部失效),
#     属于不可接受的生产风险。
#   3) 真正的重活(编码)由 ffmpeg 子进程完成, PowerShell 只需在等待期间保持界面响应,
#     因此用 DispatcherTimer 轮询进程状态即可, 无需多线程。
function Start-Slim {
    if (-not $script:FFmpegPath) { & $script:fnAddVsLog "未找到 ffmpeg.exe" 'Error'; return }

    $files = @()
    if ($script:EncInputMode -eq 'folder') {
        $dir = $script:EncInputPath
        if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
            & $script:fnAddVsLog "文件夹不存在: $dir" 'Error'; return
        }
        $files = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $script:VideoExts -contains $_.Extension.ToLower() })
    }
    else {
        if ([string]::IsNullOrWhiteSpace($script:EncInputPath) -or -not (Test-Path -LiteralPath $script:EncInputPath -PathType Leaf)) {
            & $script:fnAddVsLog "文件不存在" 'Error'; return
        }
        $files = @(Get-Item -LiteralPath $script:EncInputPath)
    }

    if ($files.Count -eq 0) { & $script:fnAddVsLog "未找到视频文件" 'Warning'; return }

    # 初始化状态机
    $script:SlimFiles   = $files
    $script:SlimTotal   = $files.Count
    $script:SlimIdx     = 0
    $script:SlimProc    = $null
    $script:SlimDone    = 0
    $script:SlimSuccess = 0
    $script:SlimFailed  = 0
    $script:SlimSaved   = [double]0
    $script:SlimAbort   = $false

    & $script:fnAddVsLog "========== 开始视频瘦身 (共 $($files.Count) 个) ==========" 'Info'
    & $script:fnStepSlim
    $script:BgTimer.Start()
}

# 状态机的一步: 结算已结束的进程 -> 启动下一个文件
function Step-Slim {
    try {
        # 1) 结算上一个进程
        if ($script:SlimProc) {
            if (-not $script:SlimProc.HasExited) {
                # 仍在编码: 刷新当前文件的百分比后等待下一次 tick
                $pct = & $script:fnReadProgress -ProgressFile $script:SlimProgressFile -DurationSec $script:SlimCurDuration
                $script:SlimPct = $pct
                & $script:fnUpdateVsProgress $script:SlimDone $script:SlimTotal $pct

                # 定期在日志区打印进度, 便于确认"还在动"以及单个文件的进度。
                # 双触发条件: 百分比每涨 5% 打一次(进度快时), 或距上次打印超过 10 秒(进度慢/卡住时)。
                $now = Get-Date
                $elapsed = ($now - $script:SlimLogTime).TotalSeconds
                # SlimLoggedPct 初始为 -100, 因此每个文件的第一次 tick 一定会打印一条, 确认任务已开始
                if (($pct - $script:SlimLoggedPct) -ge 5 -or $elapsed -ge 10) {
                    $speedInfo = ''
                    if ($script:SlimCurDuration -gt 0) {
                        $doneSec = $script:SlimCurDuration * $pct / 100.0
                        $speedInfo = (" · 已编码 {0}/{1}" -f (& $script:fnFormatTime $doneSec), (& $script:fnFormatTime $script:SlimCurDuration))
                    }
                    $elapsedTotal = ''
                    if ($script:SlimStartTime) {
                        $elapsedTotal = (" · 用时 {0}" -f (& $script:fnFormatTime ([int](( $now - $script:SlimStartTime).TotalSeconds))))
                    }
                    & $script:fnAddVsLog ("  ⏳ 进度 $pct%$speedInfo$elapsedTotal") 'Info'
                    $script:SlimLoggedPct = $pct
                    $script:SlimLogTime = $now
                }
                return
            }

            $code    = $script:SlimProc.ExitCode
            $f       = $script:SlimCur
            $outPath = $script:SlimOut
            $srcSize = $script:SlimSrcSize
            $script:SlimProc = $null
            # 清理本文件的进度文件
            if ($script:SlimProgressFile) {
                Remove-Item -LiteralPath $script:SlimProgressFile -Force -ErrorAction SilentlyContinue
                $script:SlimProgressFile = ''
            }

            if ($code -eq 0 -and (Test-Path -LiteralPath $outPath)) {
                $newSize = (Get-Item -LiteralPath $outPath).Length
                $saved = $srcSize - $newSize
                if ($saved -gt 0) { $script:SlimSaved += $saved }
                $pct = if ($srcSize -gt 0) { [math]::Round(($newSize / $srcSize) * 100) } else { 100 }
                # 附带本文件编码耗时, 便于评估后续任务时间
                $cost = ''
                if ($script:SlimFileStart) {
                    $cost = (" · 耗时 {0}" -f (& $script:fnFormatTime (((Get-Date) - $script:SlimFileStart).TotalSeconds)))
                }
                & $script:fnAddVsLog ("  OK: " + (& $script:fnFormatSize $srcSize) + ' -> ' + (& $script:fnFormatSize $newSize) + " (压缩到 $pct%$cost)") 'Success'
                $script:SlimSuccess++

                if (-not $script:EncKeepSource -and $f) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    & $script:fnAddVsLog "  已删除源文件(未勾选保留源文件): $(Split-Path $f.FullName -Leaf)" 'Warning'
                }
            }
            else {
                & $script:fnAddVsLog "  失败, ffmpeg 退出码: $code" 'Error'
                $script:SlimFailed++
            }

            $script:SlimDone++
            & $script:fnUpdateVsProgress $script:SlimDone $script:SlimTotal
        }

        # 2) 中止或全部完成
        if ($script:SlimAbort) {
            $script:BgTimer.Stop()
            & $script:fnAddVsLog "用户已中止" 'Warning'
            & $script:fnFinishSlim
            return
        }
        if ($script:SlimIdx -ge $script:SlimFiles.Count) {
            $script:BgTimer.Stop()
            & $script:fnFinishSlim
            return
        }

        # 3) 启动下一个文件
        $f = $script:SlimFiles[$script:SlimIdx]
        $script:SlimIdx++

        $info = & $script:fnGetVideoInfo -Path $f.FullName -Ctx $script:Ctx
        $srcSize = $info.SizeBytes

        $outDir = $script:EncOutDir
        if ([string]::IsNullOrWhiteSpace($outDir) -or -not (Test-Path -LiteralPath $outDir)) { $outDir = $f.DirectoryName }

        # 输出扩展名: 按「输出格式」下拉决定(自动模式沿用源格式)
        $ext = & $script:fnGetOutputExt -Info $info -Ctx $script:Ctx

        $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $outPath = & $script:fnResolveFileConflict (Join-Path $outDir ($base + '_slim' + $ext))

        # 进度文件: 交给 ffmpeg 写, 状态机读取以计算实时百分比
        $script:SlimProgressFile = Join-Path ([IO.Path]::GetTempPath()) ("vslim_prog_{0}_{1}.txt" -f $PID, $script:SlimIdx)
        Remove-Item -LiteralPath $script:SlimProgressFile -Force -ErrorAction SilentlyContinue

        & $script:fnAddVsLog "[$script:SlimIdx/$script:SlimTotal] $(Split-Path $f.FullName -Leaf) -> $(Split-Path $outPath -Leaf)" 'Info'
        $ffArgs = & $script:fnGetEncodeArgs -Info $info -OutPath $outPath -Ctx $script:Ctx -ProgressFile $script:SlimProgressFile
        & $script:fnAddVsLog ("execute: `"$script:FFmpegPath`" " + ($ffArgs -join ' ')) 'Cmd'

        # 若因容器限制自动换了编码器(如 WebM 不支持 H.264), 明确告知
        if ($script:LastVCodecAdapted) {
            & $script:fnAddVsLog ("  注意: 该容器不支持所选编码器, 已自动改用 $script:LastVCodec") 'Warning'
        }
        # 显卡编码 + 10bit: 旧卡(如 GTX 960)不支持 10bit 硬编码, 已强制转为 8bit
        if ($script:LastNvencForced8) {
            & $script:fnAddVsLog "  注意: 显卡编码已强制改用 8bit (GTX 960 等旧卡不支持 10bit 硬编码)" 'Warning'
        }
        # 字幕在非 MKV 容器中降级为纯文本
        if ($script:LastSubDowngraded) {
            & $script:fnAddVsLog "  注意: 该容器不支持 ASS 特效, 字幕已转为纯文本(丢失特效/定位/字体), 要完整保留请选 MKV" 'Warning'
        }
        if ($script:LastSubsSkipped) {
            & $script:fnAddVsLog "  注意: 该容器不支持字幕流, 已跳过字幕" 'Warning'
        }

        $script:SlimCur     = $f
        $script:SlimOut     = $outPath
        $script:SlimSrcSize = $srcSize
        $script:SlimCurDuration = $info.DurationSec   # 用于把 out_time_us 换算成百分比
        $script:SlimPct     = 0
        # 重置进度日志节流状态(每个文件独立计数), 并记录本文件开始时间
        $script:SlimLoggedPct = -100
        $script:SlimLogTime   = Get-Date
        $script:SlimFileStart = Get-Date
        if (-not $script:SlimStartTime) { $script:SlimStartTime = Get-Date }
        # 不阻塞: ffmpeg 在子进程中跑, 定时器轮询其状态, 界面保持响应
        $script:SlimProc = & $script:fnStartAsyncProc -Exe $script:FFmpegPath -ArgLine ($ffArgs -join ' ')
    }
    catch {
        & $script:fnAddVsLog "执行异常: $($_.Exception.Message)" 'Error'
        $script:BgTimer.Stop()
        & $script:fnFinishSlim
    }
}

# 收尾: 汇总并恢复按钮
function Finish-Slim {
    $failed = $script:SlimFailed
    & $script:fnAddVsLog ("========== 完成: 成功 $($script:SlimSuccess), 失败 $failed ==========") $(if ($failed -eq 0) { 'Success' } else { 'Warning' })
    if ($script:SlimSaved -gt 0) { & $script:fnAddVsLog ("累计节省空间: " + (& $script:fnFormatSize $script:SlimSaved)) 'Success' }
    # 清理残留的进度文件
    if ($script:SlimProgressFile) {
        Remove-Item -LiteralPath $script:SlimProgressFile -Force -ErrorAction SilentlyContinue
        $script:SlimProgressFile = ''
    }
    # 打印总耗时
    if ($script:SlimStartTime) {
        $totalSec = ((Get-Date) - $script:SlimStartTime).TotalSeconds
        & $script:fnAddVsLog ("总用时 " + (& $script:fnFormatTime $totalSec)) 'Info'
        $script:SlimStartTime = $null
    }
    $script:btnStart.IsEnabled = $true
    $script:btnStop.IsEnabled  = $false
    $script:prgBar.Value = 0
    $script:txtProgress.Text = "就绪"
}

# ============================================================================
# UI (XAML)
# ============================================================================
$xaml = @'
<ScrollViewer xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
              xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
              Background="#1E1E1E" Padding="16">
  <StackPanel>

    <TextBlock Text="🎬 视频瘦身" FontSize="20" FontWeight="Bold" Foreground="#4FC3F7" Margin="0,0,0,12"/>

    <!-- 输入选择 -->
    <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
      <RadioButton x:Name="RdoFile" Content="📄 单个文件" GroupName="InputMode" IsChecked="True"
                   Foreground="#FFFFFF" VerticalAlignment="Center" Margin="0,0,16,0"/>
      <RadioButton x:Name="RdoFolder" Content="📁 文件夹（批量）" GroupName="InputMode"
                   Foreground="#FFFFFF" VerticalAlignment="Center"/>
    </StackPanel>
    <Grid Margin="0,0,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="TxtInput" Grid.Column="0" Background="#2D2D2D" Foreground="#FFFFFF"
               BorderBrush="#455A64" Padding="6" IsReadOnly="True" Text="未选择"/>
      <Button x:Name="BtnBrowseInput" Grid.Column="1" Content="选择..." Margin="6,0,0,0"
              Background="#37474F" Foreground="#FFFFFF" Padding="12,4" BorderThickness="0"/>
    </Grid>

    <!-- 输出目录 -->
    <TextBlock Text="输出目录（留空则输出到源文件同目录）" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <Grid Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="TxtOutDir" Grid.Column="0" Background="#2D2D2D" Foreground="#FFFFFF"
               BorderBrush="#455A64" Padding="6"/>
      <Button x:Name="BtnBrowseOut" Grid.Column="1" Content="选择..." Margin="6,0,0,0"
              Background="#37474F" Foreground="#FFFFFF" Padding="12,4" BorderThickness="0"/>
    </Grid>

    <!-- 输出格式 -->
    <TextBlock Text="输出格式（转码后的容器，音频选「复制」时沿用源格式更稳妥）" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
      <ComboBox x:Name="CmbOutFormat" SelectedIndex="1" Width="170" Height="26"
                Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
        <ComboBoxItem Content="自动（沿用源格式）" Foreground="#000000"/>
        <ComboBoxItem Content="MP4 (.mp4)" Foreground="#000000"/>
        <ComboBoxItem Content="MKV (.mkv)" Foreground="#000000"/>
        <ComboBoxItem Content="MOV (.mov)" Foreground="#000000"/>
        <ComboBoxItem Content="AVI (.avi)" Foreground="#000000"/>
        <ComboBoxItem Content="WebM (.webm)" Foreground="#000000"/>
      </ComboBox>
      <TextBlock x:Name="TxtFormatHint" Text="" Foreground="#888888" FontSize="11"
                 VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <!-- 视频信息 -->
    <TextBlock Text="📋 视频信息" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <TextBox x:Name="TxtInfo" Height="150" AcceptsReturn="True" IsReadOnly="True"
             TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
             Background="#161616" Foreground="#D4D4D4" BorderBrush="#455A64"
             FontFamily="Consolas" FontSize="12" Padding="6" Margin="0,0,0,10"
             Text="请先选择一个视频文件"/>

    <!-- 转换场景 -->
    <TextBlock Text="🎯 转换场景" Foreground="#B0BEC5" Margin="0,4,0,4"/>
    <Border Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
      <StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
          <RadioButton x:Name="RdoS1" GroupName="Scene" Content="① 4K 超清 · HEVC CRF18 10bit"
                       Foreground="#FFFFFF" VerticalAlignment="Center" Width="230"/>
          <TextBlock x:Name="TxtS1" Text="" Foreground="#BBBBBB" FontSize="11"
                     VerticalAlignment="Center" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
          <RadioButton x:Name="RdoS2" GroupName="Scene" Content="② 1080p 均衡 · HEVC CRF22 8bit"
                       IsChecked="True" Foreground="#FFFFFF" VerticalAlignment="Center" Width="230"/>
          <TextBlock x:Name="TxtS2" Text="" Foreground="#BBBBBB" FontSize="11"
                     VerticalAlignment="Center" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
          <RadioButton x:Name="RdoS3" GroupName="Scene" Content="③ 720p 高压缩 · HEVC CRF26 8bit"
                       Foreground="#FFFFFF" VerticalAlignment="Center" Width="230"/>
          <TextBlock x:Name="TxtS3" Text="" Foreground="#BBBBBB" FontSize="11"
                     VerticalAlignment="Center" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
          <RadioButton x:Name="RdoS4" GroupName="Scene" Content="④ 1080p 最大兼容 · H.264 CRF23 8bit"
                       Foreground="#FFFFFF" VerticalAlignment="Center" Width="230"/>
          <TextBlock x:Name="TxtS4" Text="" Foreground="#BBBBBB" FontSize="11"
                     VerticalAlignment="Center" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="RdoCustom" GroupName="Scene" Content="⑤ 自定义参数"
                       Foreground="#FFFFFF" VerticalAlignment="Center" Width="230"/>
          <TextBlock Text="自行指定编码器 / CRF / 色深 / 分辨率 / 音频" Foreground="#888888"
                     FontSize="11" VerticalAlignment="Center"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- 自定义参数 -->
    <Border x:Name="PanelCustom" Background="#252525" CornerRadius="6" Padding="12,8"
            Margin="0,0,0,10" IsEnabled="False" Opacity="0.5">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,6">
          <TextBlock Text="视频编码:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,4,0"/>
          <ComboBox x:Name="CmbVCodec" SelectedIndex="0" Width="170" Height="26"
                    Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="HEVC (libx265·CPU)" Foreground="#000000"/>
            <ComboBoxItem Content="H.264 (libx264·CPU)" Foreground="#000000"/>
            <ComboBoxItem Content="AV1 (libsvtav1·CPU)" Foreground="#000000"/>
            <ComboBoxItem Content="复制 (不重编码)" Foreground="#000000"/>
            <ComboBoxItem Content="⚡ HEVC NVENC (显卡)" Foreground="#000000"/>
            <ComboBoxItem Content="⚡ H.264 NVENC (显卡)" Foreground="#000000"/>
          </ComboBox>
          <TextBlock Text="CRF:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,4,0"/>
          <ComboBox x:Name="CmbCRF" SelectedIndex="1" Width="60" Height="26"
                    Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="18" Foreground="#000000"/>
            <ComboBoxItem Content="20" Foreground="#000000"/>
            <ComboBoxItem Content="22" Foreground="#000000"/>
            <ComboBoxItem Content="24" Foreground="#000000"/>
            <ComboBoxItem Content="26" Foreground="#000000"/>
            <ComboBoxItem Content="28" Foreground="#000000"/>
            <ComboBoxItem Content="32" Foreground="#000000"/>
            <ComboBoxItem Content="36" Foreground="#000000"/>
            <ComboBoxItem Content="40" Foreground="#000000"/>
            <ComboBoxItem Content="44" Foreground="#000000"/>
          </ComboBox>
          <TextBlock Text="色深:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,4,0"/>
          <ComboBox x:Name="CmbDepth" SelectedIndex="0" Width="70" Height="26"
                    Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="8bit" Foreground="#000000"/>
            <ComboBoxItem Content="10bit" Foreground="#000000"/>
          </ComboBox>
        </StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal">
          <TextBlock Text="分辨率:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="0,0,4,0"/>
          <ComboBox x:Name="CmbRes" SelectedIndex="0" Width="110" Height="26"
                    Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="原分辨率" Foreground="#000000"/>
            <ComboBoxItem Content="2160p (4K)" Foreground="#000000"/>
            <ComboBoxItem Content="1080p" Foreground="#000000"/>
            <ComboBoxItem Content="720p" Foreground="#000000"/>
            <ComboBoxItem Content="480p" Foreground="#000000"/>
          </ComboBox>
          <TextBlock Text="音频:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,4,0"/>
          <ComboBox x:Name="CmbACodec" SelectedIndex="1" Width="120" Height="26"
                    Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="复制" Foreground="#000000"/>
            <ComboBoxItem Content="AAC 128k" Foreground="#000000"/>
            <ComboBoxItem Content="AAC 192k" Foreground="#000000"/>
            <ComboBoxItem Content="AAC 256k" Foreground="#000000"/>
            <ComboBoxItem Content="MP3 192k" Foreground="#000000"/>
            <ComboBoxItem Content="无音频" Foreground="#000000"/>
          </ComboBox>
          <TextBlock Text="速度:" Foreground="#CCCCCC" VerticalAlignment="Center" Margin="12,0,4,0"/>
          <ComboBox x:Name="CmbPreset" SelectedIndex="1" Width="90" Height="26"
                    Background="#2D2D2D" Foreground="#000000" BorderBrush="#555">
            <ComboBoxItem Content="fast" Foreground="#000000"/>
            <ComboBoxItem Content="medium" Foreground="#000000"/>
            <ComboBoxItem Content="slow" Foreground="#000000"/>
          </ComboBox>
        </StackPanel>
      </Grid>
    </Border>

    <!-- 保留内容 -->
    <TextBlock Text="🎞 保留内容（默认只保留第 1 条音轨、不含字幕）" Foreground="#B0BEC5" Margin="0,4,0,4"/>
    <Border Background="#252525" CornerRadius="6" Padding="12,8" Margin="0,0,0,8">
      <StackPanel>
        <CheckBox x:Name="ChkAllAudio" Content="保留所有音轨（双语音/评论轨等，体积会增加）"
                  IsChecked="False" Foreground="#FFFFFF" Margin="0,0,0,4"/>
        <CheckBox x:Name="ChkAllSubs" Content="保留所有字幕（含所需字体附件；MP4 不支持 ASS 特效，建议输出 MKV）"
                  IsChecked="False" Foreground="#FFFFFF" Margin="0,0,0,4"/>
        <StackPanel Orientation="Horizontal">
          <CheckBox x:Name="ChkCopyAudio" Content="复制音频（不重编码，保住 FLAC 等无损音质）"
                    IsChecked="False" Foreground="#FFFFFF" VerticalAlignment="Center" Margin="0,0,12,0"/>
          <TextBlock x:Name="TxtAudioHint" Text="" Foreground="#888888" FontSize="11"
                     VerticalAlignment="Center" TextWrapping="Wrap"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- 选项 -->
    <CheckBox x:Name="ChkKeepSource" Content="转换后保留源文件（不勾选则转换成功后删除原文件）"
              IsChecked="True" Foreground="#FFD93D" Margin="0,0,0,10"/>

    <!-- 执行 -->
    <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
      <Button x:Name="BtnStart" Content="▶ 开始瘦身" Background="#2E7D32" Foreground="#FFFFFF"
              Padding="16,8" BorderThickness="0" FontWeight="Bold"/>
      <Button x:Name="BtnStop" Content="停止" Background="#C62828" Foreground="#FFFFFF"
              Padding="16,8" BorderThickness="0" Margin="10,0,0,0" IsEnabled="False"/>
      <Button x:Name="BtnClearLog" Content="清空日志" Background="#37474F" Foreground="#FFFFFF"
              Padding="14,8" BorderThickness="0" Margin="10,0,0,0"/>
    </StackPanel>

    <ProgressBar x:Name="PrgBar" Height="18" Minimum="0" Maximum="100" Value="0"
                 Background="#2D2D2D" Foreground="#4FC3F7" Margin="0,0,0,4"/>
    <TextBlock x:Name="TxtProgress" Text="就绪" Foreground="#B0BEC5" Margin="0,0,0,8"/>

    <!-- 日志 -->
    <TextBlock Text="日志" Foreground="#B0BEC5" Margin="0,4,0,2"/>
    <ListBox x:Name="LstLog" Height="180" Background="#161616" Foreground="#D0D0D0"
             BorderBrush="#455A64" FontFamily="Consolas" ScrollViewer.VerticalScrollBarVisibility="Auto"/>
  </StackPanel>
</ScrollViewer>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$ui = [Windows.Markup.XamlReader]::Load($reader)

# 绑定控件引用
$script:ui            = $ui
$script:txtInput      = $ui.FindName("TxtInput")
$script:txtOutDir     = $ui.FindName("TxtOutDir")
$script:txtInfo       = $ui.FindName("TxtInfo")
$script:cmbVCodec     = $ui.FindName("CmbVCodec")
$script:cmbCRF        = $ui.FindName("CmbCRF")
$script:cmbDepth      = $ui.FindName("CmbDepth")
$script:cmbRes        = $ui.FindName("CmbRes")
$script:cmbACodec     = $ui.FindName("CmbACodec")
$script:cmbPreset     = $ui.FindName("CmbPreset")
$script:cmbOutFormat  = $ui.FindName("CmbOutFormat")
$script:txtFormatHint = $ui.FindName("TxtFormatHint")
$script:panelCustom   = $ui.FindName("PanelCustom")
$script:rdoCustom     = $ui.FindName("RdoCustom")
$script:chkKeepSource = $ui.FindName("ChkKeepSource")
$script:chkAllAudio   = $ui.FindName("ChkAllAudio")
$script:chkAllSubs    = $ui.FindName("ChkAllSubs")
$script:chkCopyAudio  = $ui.FindName("ChkCopyAudio")
$script:txtAudioHint  = $ui.FindName("TxtAudioHint")
$script:btnStart      = $ui.FindName("BtnStart")
$script:btnStop       = $ui.FindName("BtnStop")
$script:prgBar        = $ui.FindName("PrgBar")
$script:txtProgress   = $ui.FindName("TxtProgress")
$script:lstLog        = $ui.FindName("LstLog")
# ★ 输入模式单选按钮必须绑定: 漏绑会让 $script:rdoFolder 为 $null,
#   导致 $null.IsChecked 为 $null -> 永远走「文件」分支, 文件夹模式失效。
$script:rdoFile       = $ui.FindName("RdoFile")
$script:rdoFolder     = $ui.FindName("RdoFolder")

$script:fnWriteLog = (Get-Command Write-ToolLog).ScriptBlock

# 判断当前是否为「文件夹（批量）」模式。
# 优先用已绑定的引用, 取不到时回退到 FindName, 避免作用域变量失效导致模式判断错误。
function Test-FolderMode {
    $rb = $script:rdoFolder
    if (-not $rb -and $script:ui) { $rb = $script:ui.FindName("RdoFolder") }
    return [bool]($rb -and $rb.IsChecked)
}

# ---------- 选择对话框 ----------
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
        $dlg.Filter = "视频文件|*.mp4;*.mkv;*.avi;*.mov;*.flv;*.wmv;*.webm;*.m4v;*.ts;*.mpg;*.mpeg;*.3gp|所有文件|*.*"
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

# ---------- 函数委托绑定 ----------
# ★ 关键: Main.ps1 用 . $scriptPath (dot-source) 加载本脚本, 普通 function 会定义进
#   Set-Tool 的局部作用域, 该函数返回后作用域销毁, 事件回调(之后才触发)就找不到它们。
#   因此必须绑定到 $script: 作用域(即 Main.ps1 的脚本作用域)并用 & $script:fnXxx 调用。
#   这与 audioVedioTools.ps1 / WindowLayout.ps1 的既有约定一致。
$script:fnAddVsLog           = (Get-Command Add-VsLog).ScriptBlock
$script:fnAppendLog          = (Get-Command Append-VsLogLine).ScriptBlock
$script:fnUpdateVsProgress   = (Get-Command Update-VsProgress).ScriptBlock
$script:fnFormatSize         = (Get-Command Format-Size).ScriptBlock
$script:fnFormatTime         = (Get-Command Format-Time).ScriptBlock
$script:fnGetCodecName       = (Get-Command Get-CodecName).ScriptBlock
$script:fnGetBitDepth        = (Get-Command Get-BitDepth).ScriptBlock
$script:fnGetVideoInfo       = (Get-Command Get-VideoInfo).ScriptBlock
$script:fnCompleteInfo       = (Get-Command Complete-VideoInfo).ScriptBlock
$script:fnFormatVideoInfo    = (Get-Command Format-VideoInfo).ScriptBlock
$script:fnUpdateScenarios    = (Get-Command Update-Scenarios).ScriptBlock
$script:fnShowInfo           = (Get-Command Show-Info).ScriptBlock
$script:fnGetEncodeArgs      = (Get-Command Get-EncodeArgs).ScriptBlock
$script:fnGetOutputExt       = (Get-Command Get-OutputExtension).ScriptBlock
$script:fnGetCompatibleCodec = (Get-Command Get-CompatibleVCodec).ScriptBlock
$script:fnTestNvenc          = (Get-Command Test-NvencCodec).ScriptBlock
$script:fnReadProgress       = (Get-Command Read-EncodeProgress).ScriptBlock
$script:fnResolveFileConflict = (Get-Command Resolve-FileConflict).ScriptBlock
$script:fnStartSlim          = (Get-Command Start-Slim).ScriptBlock
$script:fnStepSlim           = (Get-Command Step-Slim).ScriptBlock
$script:fnFinishSlim         = (Get-Command Finish-Slim).ScriptBlock
$script:fnStartAsyncProc     = (Get-Command Start-AsyncProcess).ScriptBlock
$script:fnSelectInput        = (Get-Command Select-InputPath).ScriptBlock
$script:fnTestFolderMode     = (Get-Command Test-FolderMode).ScriptBlock
$script:fnSelectOutDir       = (Get-Command Select-OutDir).ScriptBlock
$script:fnInvokeOnUi         = (Get-Command Invoke-OnUiThread).ScriptBlock

# 状态机计时器(UI 线程): 轮询 ffmpeg 子进程并推进到下一个文件
$script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(300)
# ★ 把推进用的脚本块挂在计时器自身的 Tag 上(CLR 属性, 不依赖 PowerShell 作用域)。
#   若只在 ScriptBlock 内引用 $script:fnStepSlim, 一旦该作用域被回收变量会变成 $null,
#   执行 & $null 就会抛 BadExpression("'&' 后面的表达式生成无效的对象")。
$script:BgTimer.Tag = (Get-Command Step-Slim).ScriptBlock
$script:BgTimer.Add_Tick({
    # 按优先级取计时器: 事件发送者($this) > $args[0] > $script:BgTimer
    $tmr = $this
    if (-not $tmr -and $args.Count -gt 0) { $tmr = $args[0] }
    if (-not $tmr) { $tmr = $script:BgTimer }
    # 优先用 Tag 上挂的脚本块, 其次回退到作用域变量
    $fn = if ($tmr) { $tmr.Tag } else { $null }
    if (-not $fn) { $fn = $script:fnStepSlim }
    # 仍取不到就静默跳过, 避免抛异常刷屏
    if ($fn) { & $fn }
})

# 状态机状态
$script:SlimFiles = @(); $script:SlimTotal = 0; $script:SlimIdx = 0
$script:SlimProc = $null; $script:SlimCur = $null
$script:SlimOut = ''; $script:SlimSrcSize = 0
$script:SlimDone = 0; $script:SlimSuccess = 0; $script:SlimFailed = 0
$script:SlimSaved = [double]0; $script:SlimAbort = $false
$script:SlimFileStart = $null

# ---------- 依赖/配置容器 ----------
# ★ 后台任务在【独立 Runspace】中运行, 那里没有本脚本的 $script: 作用域。
#   因此把后台所需的一切(配置 + 函数委托 + 线程安全队列 + 停止信号)打包进 $Ctx 传进去。
$script:Ctx = @{
    Config = @{
        FFmpegPath = $script:FFmpegPath; FFprobePath = $script:FFprobePath
        ScriptDir = $script:ScriptDir; Scenarios = $script:Scenarios; VideoExts = $script:VideoExts
        EncInputMode = 'file'; EncInputPath = ''; EncOutDir = ''
        EncUseCustom = $false; EncScenario = 1
        EncVCodec = 'libx265'; EncCRF = 22; EncDepth = 8; EncRes = 0
        EncACodec = 'aac192'; EncPreset = 'medium'; EncKeepSource = $true
        EncOutFormat = 1
        EncAllAudio = $false; EncAllSubs = $false; EncCopyAudio = $false
    }
    Fns = @{
        GetVideoInfo        = (Get-Command Get-VideoInfo).ScriptBlock
        GetCodecName        = (Get-Command Get-CodecName).ScriptBlock
        GetBitDepth         = (Get-Command Get-BitDepth).ScriptBlock
        CompleteInfo        = (Get-Command Complete-VideoInfo).ScriptBlock
        FormatSize          = (Get-Command Format-Size).ScriptBlock
        GetEncodeArgs       = (Get-Command Get-EncodeArgs).ScriptBlock
        ResolveFileConflict = (Get-Command Resolve-FileConflict).ScriptBlock
        StartSlim           = (Get-Command Start-Slim).ScriptBlock
    }
    LogQ  = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    ProgQ = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    Sync  = [hashtable]::Synchronized(@{ Stop = $false })
}

# ---------- 探测依赖(必须在委托绑定之后, 因为日志会用到 fnInvokeOnUi) ----------
Find-FFmpeg
if (-not $script:FFmpegPath) { & $script:fnAddVsLog "未找到 ffmpeg.exe，请放入 Tools\\lib 目录" 'Error' }
else { & $script:fnAddVsLog "ffmpeg: $script:FFmpegPath" 'Success' }
if ($script:FFprobePath) { & $script:fnAddVsLog "ffprobe: $script:FFprobePath（使用 JSON 精确解析）" 'Success' }
else { & $script:fnAddVsLog "ffprobe: 未找到，回退用 ffmpeg 解析视频信息" 'Warning' }

# 探测结果同步进 Ctx(Ctx 在 Find-FFmpeg 之前构建, 此时路径还是空的)
$script:Ctx.Config.FFmpegPath  = $script:FFmpegPath
$script:Ctx.Config.FFprobePath = $script:FFprobePath

# ---------- 事件绑定 ----------
$ui.FindName("BtnBrowseInput").Add_Click({
    $p = & $script:fnSelectInput
    if ($p) {
        $script:txtInput.Text = $p
        & $script:fnAddVsLog "已选择: $p" 'Info'
        if (-not (& $script:fnTestFolderMode)) { & $script:fnShowInfo -Path $p }
        else {
            $n = @(Get-ChildItem -LiteralPath $p -File | Where-Object { $script:VideoExts -contains $_.Extension.ToLower() }).Count
            & $script:fnAddVsLog "文件夹内发现 $n 个视频文件" 'Success'
        }
    }
})

$ui.FindName("BtnBrowseOut").Add_Click({
    $p = & $script:fnSelectOutDir
    if ($p) { $script:txtOutDir.Text = $p }
})

# 自定义参数面板：仅在选中「自定义」时启用
$script:rdoCustom.Add_Checked({ $script:panelCustom.IsEnabled = $true; $script:panelCustom.Opacity = 1 })
$script:rdoCustom.Add_Unchecked({ $script:panelCustom.IsEnabled = $false; $script:panelCustom.Opacity = 0.5 })

# 保留内容: 勾选「复制音频」时提示会忽略下方音频编码选择
$script:chkCopyAudio.Add_Checked({
    $script:txtAudioHint.Text = "已开启: 音轨原样复制, 下方「音频」下拉将被忽略"
})
$script:chkCopyAudio.Add_Unchecked({
    $script:txtAudioHint.Text = ""
})

# 保留字幕 + 非 MKV 容器: 明确警告 ASS 特效会丢失
$script:chkAllSubs.Add_Checked({
    $idx = $script:cmbOutFormat.SelectedIndex
    if ($idx -ne 0 -and $idx -ne 2) {
        & $script:fnAddVsLog "提示: 当前输出容器不是 MKV, ASS 字幕特效/字体将丢失(转为纯文本)。要完整保留请选「MKV」或「自动(沿用源格式)」。" 'Warning'
    }
})

# 输出格式切换提示
$script:cmbOutFormat.Add_SelectionChanged({
    $hint = switch ($script:cmbOutFormat.SelectedIndex) {
        0 { "沿用源文件的容器格式" }
        1 { "通用性最好，推荐" }
        2 { "支持几乎所有编码与多音轨/字幕" }
        3 { "QuickTime 容器，适合 macOS" }
        4 { "兼容性好，但对 HEVC/10bit 支持有限" }
        5 { "仅支持 VP9/AV1；若选了 H.264/HEVC 会自动改用 VP9" }
        default { "" }
    }
    $script:txtFormatHint.Text = $hint
})

$ui.FindName("BtnClearLog").Add_Click({ $script:lstLog.Items.Clear() })

$ui.FindName("BtnStop").Add_Click({
    $script:SlimAbort = $true
    # 杀掉正在编码的 ffmpeg 子进程, 让状态机立即推进到结算
    if ($script:SlimProc -and -not $script:SlimProc.HasExited) {
        try { $script:SlimProc.Kill() } catch { }
    }
    & $script:fnAddVsLog "已请求停止，正在结束当前任务..." 'Warning'
})

$ui.FindName("BtnStart").Add_Click({
    # 在 UI 线程捕获控件值, 供后台线程安全读取
    $script:EncInputMode  = if (& $script:fnTestFolderMode) { 'folder' } else { 'file' }
    $script:EncInputPath  = $script:txtInput.Text.Trim()
    $script:EncOutDir     = $script:txtOutDir.Text.Trim()
    $script:EncKeepSource = $script:chkKeepSource.IsChecked
    $script:EncUseCustom  = $script:rdoCustom.IsChecked
    $script:EncOutFormat  = $script:cmbOutFormat.SelectedIndex
    if ($script:EncOutFormat -lt 0) { $script:EncOutFormat = 1 }
    # 保留内容
    $script:EncAllAudio   = [bool]$script:chkAllAudio.IsChecked
    $script:EncAllSubs    = [bool]$script:chkAllSubs.IsChecked
    $script:EncCopyAudio  = [bool]$script:chkCopyAudio.IsChecked

    if ($script:EncUseCustom) {
        # 4/5 = 显卡(NVENC)编码, 速度远快于 CPU 软编码
        $script:EncVCodec = switch ($script:cmbVCodec.SelectedIndex) {
            0 { 'libx265' } 1 { 'libx264' } 2 { 'libsvtav1' } 3 { 'copy' }
            4 { 'hevc_nvenc' } 5 { 'h264_nvenc' }
            default { 'libx265' }
        }
        $script:EncCRF = [int]($script:cmbCRF.SelectedItem.Content)
        $script:EncDepth = if ($script:cmbDepth.SelectedIndex -eq 1) { 10 } else { 8 }
        $script:EncRes = switch ($script:cmbRes.SelectedIndex) {
            0 { 0 } 1 { 3840 } 2 { 1920 } 3 { 1280 } 4 { 854 } default { 0 }
        }
        $script:EncACodec = switch ($script:cmbACodec.SelectedIndex) {
            0 { 'copy' } 1 { 'aac128' } 2 { 'aac192' } 3 { 'aac256' } 4 { 'mp3192' } 5 { 'none' } default { 'aac192' }
        }
        $script:EncPreset = switch ($script:cmbPreset.SelectedIndex) {
            0 { 'fast' } 1 { 'medium' } 2 { 'slow' } default { 'medium' }
        }
    }
    else {
        # 找到选中的场景
        $idx = 1
        if ($script:rdoS2.IsChecked) { $idx = 1 }
        elseif ($script:rdoS1.IsChecked) { $idx = 0 }
        elseif ($script:rdoS3.IsChecked) { $idx = 2 }
        elseif ($script:rdoS4.IsChecked) { $idx = 3 }
        else { $idx = 1 }
        $script:EncScenario = $idx
        # 校验场景是否可达(按长边比较)
        $srcLong = 0
        if ($script:CurrentInfo) { $srcLong = [math]::Max($script:CurrentInfo.Width, $script:CurrentInfo.Height) }
        if ($script:CurrentInfo -and $srcLong -lt $script:Scenarios[$idx].MinSrcLong) {
            & $script:fnAddVsLog "所选场景不可达：源长边 $srcLong 不足（需要 ≥ $($script:Scenarios[$idx].MinSrcLong)），不做升频，请换场景或用自定义参数" 'Error'
            return
        }
    }

    if (-not $script:FFmpegPath) { & $script:fnAddVsLog "未找到 ffmpeg.exe" 'Error'; return }
    if ($script:EncInputPath -eq '' -or $script:EncInputPath -eq '未选择') {
        & $script:fnAddVsLog "请先选择文件或文件夹" 'Warning'; return
    }

    $script:btnStart.IsEnabled = $false
    $script:btnStop.IsEnabled = $true

    # ---- 把 UI 捕获到的值写入 Ctx.Config, 供后台 Runspace 使用 ----
    $c = $script:Ctx.Config
    $c.FFmpegPath  = $script:FFmpegPath
    $c.FFprobePath = $script:FFprobePath
    $c.EncInputMode  = $script:EncInputMode
    $c.EncInputPath  = $script:EncInputPath
    $c.EncOutDir     = $script:EncOutDir
    $c.EncKeepSource = $script:EncKeepSource
    $c.EncUseCustom  = $script:EncUseCustom
    $c.EncVCodec = $script:EncVCodec
    $c.EncCRF    = $script:EncCRF
    $c.EncDepth  = $script:EncDepth
    $c.EncRes    = $script:EncRes
    $c.EncACodec = $script:EncACodec
    $c.EncPreset = $script:EncPreset
    $c.EncScenario = $script:EncScenario
    $c.EncOutFormat = $script:EncOutFormat
    $c.EncAllAudio  = $script:EncAllAudio
    $c.EncAllSubs   = $script:EncAllSubs
    $c.EncCopyAudio = $script:EncCopyAudio
    $script:Ctx.Sync.Stop = $false

    & $script:fnAddVsLog "===== 开始视频瘦身任务 =====" 'Info'
    # 由 UI 线程的 DispatcherTimer 驱动状态机(见 Start-Slim/Step-Slim 注释)
    & $script:fnStartSlim
})

# 场景单选引用(供开始按钮判断)
$script:rdoS1 = $ui.FindName("RdoS1")
$script:rdoS2 = $ui.FindName("RdoS2")
$script:rdoS3 = $ui.FindName("RdoS3")
$script:rdoS4 = $ui.FindName("RdoS4")

# ========== 返回或显示 ==========
if ($Global:MainWindow) {
    & $script:fnWriteLog "VideoSlim v1.6 已加载 (TagFix+进度日志)" -Type Success
    return $ui
}
else {
    $window = New-Object System.Windows.Window
    $window.Title = '视频瘦身'
    $window.Width = 780
    $window.Height = 900
    $window.WindowStartupLocation = "CenterScreen"
    $window.Content = $ui
    $window.Background = "#1E1E1E"
    & $script:fnWriteLog "VideoSlim v1.0 启动成功" -Type Success
    $window.ShowDialog() | Out-Null
}
