<#
    DeskPet.ps1 —— 单文件 Windows 桌面宠物
    无需安装 Python / Node，任何 Win10 / Win11 自带 PowerShell 即可运行。

    功能：
      · 透明无边框窗口，图片形象悬浮在桌面上，总在最前、点击不抢焦点
      · 待机呼吸起伏 / 上下浮动 / 随机眨眼 / 偶尔自言自语（气泡）
      · 鼠标靠近会转身面向鼠标并微微倾斜；贴到脸上会被"挠痒"跳起来
      · 单击 → 开心跳一下；双击 → 翻个跟头；拖动 → 抱起（悬空摆荡）；
        松手 → 带惯性掉落并回弹落地
      · 右键菜单：说话 / 大小 / 置顶 / 锁定 / 换形象 / 打开素材目录 / 退出
      · 把图片或 GIF 直接拖到宠物身上即可换形象
      · 像素风小图自动放大；素材目录里放 blink / happy / 行走 帧即自动启用

    启动：双击「启动桌宠.vbs」（静默、无黑框）
          或 powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\DeskPet.ps1
#>
[CmdletBinding()]
param(
    [string]$PetPath,
    [switch]$DebugImage,
    [switch]$AutoCloseAfter,
    [int]$Seconds = 0,
    [switch]$DumpState,
    [switch]$AtCursor
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ────────────────────────────── 原生互操作 ──────────────────────────────
if (-not ('DeskPet.Win' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DeskPet {
    public static class Win {
        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X; public int Y; }

        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        // 让程序按物理像素绘制，高 DPI 屏幕上不会发虚
        public static void DpiAware() { try { SetProcessDPIAware(); } catch { } }
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int index);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern IntPtr GetWindowLong32(IntPtr h, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int index, IntPtr value);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] static extern IntPtr SetWindowLong32(IntPtr h, int index, IntPtr value);

        const int GWL_EXSTYLE = -20;
        const long WS_EX_TOPMOST = 0x00000008;
        const long WS_EX_NOACTIVATE = 0x08000000;
        const uint SWP_NOSIZE = 0x0001;
        const uint SWP_NOMOVE = 0x0002;
        const uint SWP_NOACTIVATE = 0x0010;

        static IntPtr GetEx(IntPtr h) {
            return IntPtr.Size == 8 ? GetWindowLongPtr64(h, GWL_EXSTYLE) : GetWindowLong32(h, GWL_EXSTYLE);
        }
        static void SetEx(IntPtr h, IntPtr v) {
            if (IntPtr.Size == 8) SetWindowLongPtr64(h, GWL_EXSTYLE, v);
            else SetWindowLong32(h, GWL_EXSTYLE, v);
        }

        public static bool GetCursor(int[] outXY) {
            POINT p;
            if (!GetCursorPos(out p)) return false;
            outXY[0] = p.X; outXY[1] = p.Y;
            return true;
        }

        public static void NoActivate(IntPtr hwnd) {
            IntPtr ex = GetEx(hwnd);
            SetEx(hwnd, new IntPtr(ex.ToInt64() | WS_EX_NOACTIVATE));
        }

        public static void SetTopmost(IntPtr hwnd, bool on) {
            IntPtr ex = GetEx(hwnd);
            long v = ex.ToInt64();
            if (on) v |= WS_EX_TOPMOST; else v &= ~WS_EX_TOPMOST;
            SetEx(hwnd, new IntPtr(v));
            SetWindowPos(hwnd, new IntPtr(on ? -1 : -2), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }

        // 把文字排成"圆角气泡 + 描边字"的位图，保存为临时 PNG 供 WinForms 显示
        // 把文字排成"描边字"的透明位图（没有底色框，不会挡住角色）
        public static string RenderText(string text, string fontName, float size, int maxWidth, int maxHeight) {
            string[] lines = (text ?? "").Replace("\r", "").Split('\n');
            System.Drawing.Font font;
            try { font = new System.Drawing.Font(fontName, size, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Pixel); }
            catch { font = new System.Drawing.Font("Microsoft YaHei UI", size, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Pixel); }

            float w = 0, lineH;
            using (var probe = new System.Drawing.Bitmap(1, 1))
            using (var pg = System.Drawing.Graphics.FromImage(probe)) {
                pg.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
                lineH = pg.MeasureString("国Ag", font).Height;
                foreach (var ln in lines) {
                    float lw = pg.MeasureString(ln.Length == 0 ? " " : ln, font).Width;
                    if (lw > w) w = lw;
                }
            }

            // 描边要留够空间
            int stroke = (int)Math.Ceiling(size * 0.34f);
            int pad = stroke + 3;
            int bw = Math.Min(maxWidth, Math.Max(8, (int)Math.Ceiling(w) + pad * 2));
            int bh = Math.Min(maxHeight, Math.Max(8, (int)Math.Ceiling(lineH * lines.Length) + pad * 2));

            var outBmp = new System.Drawing.Bitmap(bw, bh, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var g = System.Drawing.Graphics.FromImage(outBmp)) {
                g.Clear(System.Drawing.Color.Transparent);      // 关键：完全透明底
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;

                var fmt = new System.Drawing.StringFormat();
                fmt.Alignment = System.Drawing.StringAlignment.Center;
                fmt.LineAlignment = System.Drawing.StringAlignment.Center;

                // 描边用 252,252,253 而不是纯白：窗口的透明色是纯白，
                // 纯白会被"抠"掉，留一点灰才能保住描边。
                using (var halo = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(255, 252, 252, 253)))
                using (var ink = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(255, 26, 26, 40))) {
                    float y = pad;
                    foreach (var ln in lines) {
                        // 八方向描边，比原来的四个偏移厚一倍
                        for (int k = 0; k < 8; k++) {
                            double ang = Math.PI * 2 * k / 8.0;
                            float ox = (float)(Math.Cos(ang) * stroke);
                            float oy = (float)(Math.Sin(ang) * stroke);
                            g.DrawString(ln, font, halo, new System.Drawing.RectangleF(ox, y + oy, bw, lineH), fmt);
                        }
                        g.DrawString(ln, font, ink, new System.Drawing.RectangleF(0, y, bw, lineH), fmt);
                        y += lineH;
                    }
                }
            }

            string tmp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "deskpet_bubble_" + Guid.NewGuid().ToString("N") + ".png");
            outBmp.Save(tmp, System.Drawing.Imaging.ImageFormat.Png);
            outBmp.Dispose();
            font.Dispose();
            return tmp;
        }
    }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms
}

# DPI 感知：必须在 Win 类型编译之后再调用
# DPI 感知会让窗口被系统二次缩放，导致尺寸对不上，这里不启用
# ────────────────────────────── 配置 ──────────────────────────────
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$AssetDir = Join-Path $Root 'assets'
if (-not (Test-Path -LiteralPath $AssetDir)) { New-Item -ItemType Directory -Path $AssetDir -Force | Out-Null }
$ConfigPath = Join-Path $Root 'pet.config.json'
$MotionPath = Join-Path $Root 'pet.motions.json'

$Defaults = [ordered]@{
    petFile      = 'assets/pet.png'
    blinks       = @('assets/blink.png')
    happy        = @('assets/happy.png')
    weight       = 0.58
    size         = 1.0
    alwaysTop    = $true
    locked       = $false
    screen       = 'small'      # small=小屏 / large=大屏 / primary / auto=跟着鼠标 / 设备名
    speech       = $true
    blinkEvery   = 4
    idleChatter  = 45
    bubbleMs     = 5000
    reduceMotion = $false
    lines        = @(
        '今天也要加油鸭', '我在这儿陪你~', '记得喝口水', '别久坐啦，起来动动',
        '休息一下眼睛吧', '摸鱼也要注意姿势哦', '你是我最喜欢的人', '……我在发呆',
        '要不要摸摸我？', '我已经盯着你很久了'
    )
    happyLines   = @('开心~', '嘿嘿', '再来一次！', '喜欢！')
}

function Read-Config {
    $cfg = [ordered]@{}
    foreach ($k in $Defaults.Keys) { $cfg[$k] = $Defaults[$k] }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $obj = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) {
                if ($Defaults.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        }
        catch { }
    }
    return $cfg
}

function Save-Config($cfg) {
    $out = [ordered]@{}
    foreach ($k in $Defaults.Keys) { $out[$k] = $cfg[$k] }
    try { ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 } catch { }
}

function Resolve-PetPath([string]$p) {
    if (-not $p) { return $null }
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return [System.IO.Path]::Combine($Root, ($p -replace '/', '\'))
}

$Config = Read-Config

if ($PetPath) {
    $resolved = Resolve-Path -LiteralPath $PetPath -ErrorAction SilentlyContinue
    if ($resolved) {
        $Config['petFile'] = $resolved.Path
        Save-Config $Config
    }
}

# ────────────────────────────── 素材加载 ──────────────────────────────
function Import-Frames([string]$path) {
    # 支持静态图 / 动态 GIF / 精灵表目录（目录里按文件名排序的图片依次成帧）
    $frames = New-Object System.Collections.ArrayList
    if (-not $path) { return $frames }
    $full = Resolve-PetPath $path
    if (-not (Test-Path -LiteralPath $full)) { return $frames }

    $item = Get-Item -LiteralPath $full
    if ($item.PSIsContainer) {
        $files = @(Get-ChildItem -LiteralPath $full -File |
            Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|bmp|gif|ico|webp)$' -and $_.Name -notmatch '^_' } |
            Sort-Object Name)
        foreach ($f in $files) {
            try { $frames.Add((New-Object System.Drawing.Bitmap $f.FullName)) | Out-Null } catch { }
        }
        return $frames
    }

    if ($item.Extension -ieq '.gif') {
        $img = [System.Drawing.Image]::FromFile($item.FullName)
        try {
            $dim = New-Object System.Drawing.Imaging.FrameDimension $img.FrameDimensionsList[0]
            $count = $img.GetFrameCount($dim)
            for ($i = 0; $i -lt [Math]::Max(1, $count); $i++) {
                $img.SelectActiveFrame($dim, $i) | Out-Null
                $clone = New-Object System.Drawing.Bitmap $img.Width, $img.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $g = [System.Drawing.Graphics]::FromImage($clone)
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.DrawImage($img, 0, 0, $img.Width, $img.Height)
                $g.Dispose()
                $frames.Add($clone) | Out-Null
            }
        }
        finally { $img.Dispose() }
        return $frames
    }

    try { $frames.Add((New-Object System.Drawing.Bitmap $item.FullName)) | Out-Null } catch { }
    return $frames
}

function Load-Set([string]$path) {
    $frames = @(Import-Frames $path)
    $frameMs = 120
    if ($path -match '\.gif$') { $frameMs = 90 }
    return [ordered]@{ frames = $frames; frameMs = $frameMs; path = $path; valid = ($frames.Count -gt 0) }
}

function New-PlaceholderImage {
    $bmp = New-Object System.Drawing.Bitmap 120, 120, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $body = New-Object System.Drawing.Drawing2D.GraphicsPath
    $body.AddEllipse(16, 28, 88, 78)
    $body.AddEllipse(28, 8, 28, 32)
    $body.AddEllipse(64, 8, 28, 32)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Point 0, 0), (New-Object System.Drawing.Point 0, 120), ([System.Drawing.Color]::FromArgb(255, 255, 186, 128)), ([System.Drawing.Color]::FromArgb(255, 255, 128, 168))
    $g.FillPath($grad, $body)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, 96, 60, 50)), 2.5
    $g.DrawPath($pen, $body)
    $eye = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 45, 35, 40))
    $g.FillEllipse($eye, 44, 58, 9, 13)
    $g.FillEllipse($eye, 70, 58, 9, 13)
    $g.FillEllipse($eye, 55, 80, 12, 8)
    $pink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 255, 110, 150))
    $g.FillEllipse($pink, 27, 74, 17, 9)
    $g.FillEllipse($pink, 79, 74, 17, 9)
    $g.Dispose(); $grad.Dispose(); $pen.Dispose(); $eye.Dispose(); $pink.Dispose(); $body.Dispose()
    return $bmp
}

function New-PetSets {
    $sets = [ordered]@{}
    $s = Load-Set $Config['petFile']
    if (-not $s['valid']) {
        $cand = Get-ChildItem -LiteralPath $AssetDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|bmp|gif|ico|webp)$' } |
            Sort-Object Length -Descending | Select-Object -First 1
        if ($cand) {
            $s = Load-Set $cand.FullName
            $Config['petFile'] = $cand.FullName
        }
    }
    $sets['pet'] = $s
    $sets['blink'] = Load-Set (@($Config['blinks']) | Select-Object -First 1)
    $sets['happy'] = Load-Set (@($Config['happy']) | Select-Object -First 1)
    return $sets
}

function New-MotionData {
    $list = New-Object System.Collections.ArrayList
    $walkSpeed = 1.6
    if (Test-Path -LiteralPath $MotionPath) {
        try {
            $raw = Get-Content -LiteralPath $MotionPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($raw.PSObject.Properties['walkSpeed']) { $walkSpeed = [double]$raw.walkSpeed }
            foreach ($m in @($raw.motions)) {
                $frames = @(Import-Frames $m.path)
                if ($frames.Count -gt 0) {
                    $list.Add([ordered]@{
                            name    = [string]$m.name
                            frames  = $frames
                            frameMs = if ($m.frameMs) { [int]$m.frameMs } else { 140 }
                        }) | Out-Null
                }
            }
        }
        catch { }
    }
    return @{ motions = $list; walkSpeed = $walkSpeed }
}

function Get-Zoom($w, $h) {
    # 不做自动放大：直接按原图尺寸显示（搜狗桌宠那种小尺寸）
    return 1.0
}

$Sets = New-PetSets
$MotionData = New-MotionData
$Motions = $MotionData['motions']

$Placeholder = $false
if (-not $Sets['pet']['valid']) {
    $Sets['pet'] = [ordered]@{ frames = @(New-PlaceholderImage); frameMs = 120; path = ''; valid = $true }
    $Placeholder = $true
}

$BaseFrames = @($Sets['pet']['frames'])
$BaseW = [double]$BaseFrames[0].Width
$BaseH = [double]$BaseFrames[0].Height

$BlinkFrames = @($Sets['blink']['frames'])
$HappyFrames = @($Sets['happy']['frames'])
$WalkFrames = @()
foreach ($mo in $Motions) {
    if ($mo.name -match '^(blink|eyesclosed|闭眼)') { if ($BlinkFrames.Count -eq 0) { $BlinkFrames = @($mo.frames) } }
    elseif ($mo.name -match '^(happy|joy|笑)') { if ($HappyFrames.Count -eq 0) { $HappyFrames = @($mo.frames) } }
    elseif ($mo.name -match '^(walk|走)') { if ($WalkFrames.Count -eq 0) { $WalkFrames = @($mo.frames) } }
}

function Get-MaxFrame([object[]]$groups) {
    $mw = 1.0; $mh = 1.0
    foreach ($grp in $groups) {
        foreach ($img in @($grp)) {
            if ($img.Width -gt $mw) { $mw = [double]$img.Width }
            if ($img.Height -gt $mh) { $mh = [double]$img.Height }
        }
    }
    return @{ w = $mw; h = $mh }
}
$maxDim = Get-MaxFrame @($BaseFrames, $BlinkFrames, $HappyFrames, $WalkFrames)
$MaxFrameW = [double]$maxDim['w']
$MaxFrameH = [double]$maxDim['h']

# ────────────────────────────── 窗口 ──────────────────────────────
$Form = New-Object System.Windows.Forms.Form
$Form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$Form.FormBorderStyle = 'None'
$Form.StartPosition = 'Manual'
$Form.ShowInTaskbar = $false
$Form.Text = 'DeskPet'
$Form.TopMost = [bool]$Config['alwaysTop']
$Form.BackColor = [System.Drawing.Color]::White
if (-not $DebugImage) { $Form.TransparencyKey = [System.Drawing.Color]::White }

$Pet = New-Object System.Windows.Forms.PictureBox
$Pet.BackColor = [System.Drawing.Color]::Transparent
$Pet.SizeMode = 'Zoom'
$Pet.Image = $BaseFrames[0]
$Form.Controls.Add($Pet)

$Bubble = New-Object System.Windows.Forms.PictureBox
$Bubble.SizeMode = 'Zoom'
$Bubble.Visible = $false
$Bubble.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($Bubble)

# 气泡字体：素材目录放 pet.ttf 即可替换
$FontName = 'Microsoft YaHei UI'
$GlyphFonts = $null
$fontFile = Join-Path $AssetDir 'pet.ttf'
if (Test-Path -LiteralPath $fontFile) {
    try {
        $GlyphFonts = New-Object System.Drawing.Text.PrivateFontCollection
        $GlyphFonts.AddFontFile($fontFile)
        if ($GlyphFonts.Families.Count -gt 0) { $FontName = $GlyphFonts.Families[0].Name }
    }
    catch { }
}

# 注：本程序的动画用"交换帧图片 + 透明窗口"实现，宠物保持清晰锐利。
#     挤压 / 悬空 / 倾斜通过窗口内的位置与尺寸微调 + 窗口位移共同完成。

# ────────────────────────────── 运行状态 ──────────────────────────────
# 桌宠固定待在哪块屏：small / large / primary / auto（跟着鼠标）/ 设备名
function Get-TargetScreen {
    $all = @([System.Windows.Forms.Screen]::AllScreens)
    if ($all.Count -eq 0) { return [System.Windows.Forms.Screen]::PrimaryScreen }
    $mode = ''
    try { $mode = [string]$Config['screen'] } catch { }
    if (-not $mode) { $mode = 'small' }

    if ($mode -eq 'auto') {
        try { return [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position) } catch { }
    }
    if ($mode -eq 'primary') { return [System.Windows.Forms.Screen]::PrimaryScreen }
    if ($mode -eq 'small' -or $mode -eq 'large') {
        $sorted = @($all | Sort-Object { [double]$_.Bounds.Width * [double]$_.Bounds.Height })
        if ($mode -eq 'small') { return $sorted[0] }
        return $sorted[$sorted.Count - 1]
    }
    foreach ($s2 in $all) { if ($s2.DeviceName -eq $mode) { return $s2 } }
    return [System.Windows.Forms.Screen]::PrimaryScreen
}

$startScreen = Get-TargetScreen
$Wa = $startScreen.WorkingArea
# 动作帧（assets\frames 下的多帧）；没有就用单张形象
$FrameDir = Join-Path $AssetDir 'frames'
$FrameOrder = @('open', 'walk', 'smile', 'sleep', 'look')
$Script:FramePaths = @()
$Script:FrameIndex = @{}
foreach ($fn in $FrameOrder) {
    $fp = Join-Path $FrameDir ($fn + '.png')
    if (Test-Path -LiteralPath $fp) {
        $Script:FrameIndex[$fn] = $Script:FramePaths.Count
        $Script:FramePaths = @($Script:FramePaths) + @($fp)
    }
}
$rigAspect = 322.0 / 450.0
if ($Script:FramePaths.Count -gt 0) {
    try {
        $probe = [System.Drawing.Image]::FromFile($Script:FramePaths[0])
        $rigAspect = [double]$probe.Width / [double]$probe.Height
        $probe.Dispose()
    }
    catch { }
}
# 显示高度固定由 size 决定（形变都在渲染器内部完成，窗口不再缩放）
$PetH = [int][Math]::Max(40, [Math]::Round(132 * [double]$Config['size']))
$PetW = [int][Math]::Max(20, [Math]::Round($PetH * $rigAspect))

if ($AtCursor) {
    # 直接出现在鼠标旁边，保证看得见
    $curPt = [System.Windows.Forms.Cursor]::Position
    $StartX = [double]($curPt.X + 40)
    $StartY = [double]($curPt.Y + 40)
}
else {
    # 默认：鼠标所在那块屏的右下角
    $StartX = [double][Math]::Max($Wa.Left + 10, $Wa.Right - $PetW - 90)
    $StartY = [double][Math]::Max($Wa.Top + 10, $Wa.Bottom - $PetH - 16)
}
# 无论怎么算，都夹回该屏可见范围
$StartX = [double][Math]::Max($Wa.Left + $PetW / 2, [Math]::Min($Wa.Right - $PetW / 2, $StartX))
$StartY = [double][Math]::Max($Wa.Top + $PetH, [Math]::Min($Wa.Bottom - 4, $StartY))

$St = [hashtable]::Synchronized(@{})
$St['petX'] = $StartX
$St['petY'] = $StartY
$St['restX'] = $StartX
$St['restY'] = $StartY
$St['tick'] = 0.0
$St['idleTime'] = 0.0
$St['draggingIdle'] = 0.0
$St['lift'] = 0.0
$St['squashY'] = 1.0
$St['appliedSquash'] = 1.0
$St['lastWinW'] = 0
$St['lastWinH'] = 0
$St['lastPetH'] = -1
$St['jit'] = 0.0
$St['spin'] = 0.0
$St['flip'] = 1.0
$St['pressed'] = $false
$St['dragging'] = $false
$St['falling'] = $false
$St['fallVelX'] = 0.0
$St['fallVelY'] = 0.0
$St['grabX'] = 0.0
$St['grabY'] = 0.0
$St['pressX'] = 0
$St['pressY'] = 0
$St['draggingVel'] = 0.0
$St['draggingVelY'] = 0.0
$St['walking'] = $false
$St['walkTargetX'] = $StartX
$St['walkTargetY'] = $StartY
$St['walkBeganAt'] = [DateTime]::MinValue
$St['walkSpeed'] = [double]$MotionData['walkSpeed']
$St['actionName'] = ''
$St['actionFrames'] = @()
$St['actionFrameMs'] = 120
$St['actionUntil'] = [DateTime]::MinValue
$St['frameIndex'] = 0
$St['lastFrameAt'] = [DateTime]::MinValue
$St['blinkSquashUntil'] = [DateTime]::MinValue
$St['nextBlinkAt'] = [DateTime]::Now.AddSeconds(3)
$St['nextChatterAt'] = [DateTime]::Now.AddSeconds([Math]::Max(10, [double]$Config['idleChatter']))
$St['nextWander'] = [DateTime]::Now.AddSeconds(30)
$St['dist'] = 9999.0

$Script:LastTickle = [DateTime]::MinValue
$Script:BubbleUntil = [DateTime]::MinValue
$Script:CursorXY = New-Object int[] 2
$Script:LastNow = [DateTime]::Now
$Script:LastClick = [DateTime]::MinValue
$Script:LogErrors = $true
# 单实例：先关掉上一次的实例，再记录自己的 PID
try {
    $pidPath = Join-Path $Root 'pet.pid'
    if (Test-Path -LiteralPath $pidPath) {
        $oldPid = 0
        $rawPid = ((Get-Content -LiteralPath $pidPath -Raw) -replace '\s', '')
        if ([int]::TryParse($rawPid, [ref]$oldPid) -and $oldPid -gt 0 -and $oldPid -ne $PID) {
            $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProc -and $oldProc.ProcessName -eq 'powershell') {
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Set-Content -LiteralPath $pidPath -Value $PID -Encoding ASCII
}
catch { }
$Script:ProbeRender = ($env:DESKPET_PROBE -eq "1")
$Script:ProbeCount = 0

# ────────────── 镜像帧：让"看向鼠标"有真实的视觉反馈 ──────────────
$MirrorFrames = @()
foreach ($f in $BaseFrames) {
    try {
        $c = New-Object System.Drawing.Bitmap $f.Width, $f.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gm = [System.Drawing.Graphics]::FromImage($c)
        $gm.Clear([System.Drawing.Color]::Transparent)
        $gm.DrawImage($f, 0, 0, $f.Width, $f.Height)
        $gm.Dispose()
        $c.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX)
        $MirrorFrames += $c
    }
    catch { }
}

# ────────────── 载入大脑 ──────────────
. (Join-Path $Root 'pet.brain.ps1')

# ────────────── 命令行：只输出一次决策 JSON，不开窗口 ──────────────
if ($DumpState) {
    try {
        $St['dist'] = 9999.0
        Update-BrainSenses 0.2
        $d = Get-DesiredState
        $Script:Br['state'] = [string]$d[0]
        $Script:Br['emotion'] = Get-EmotionForState ([string]$d[0])
        $Script:Br['reason'] = [string]$d[1]
        $act = Get-ActionForState ([string]$d[0])
        $Script:Br['action'] = [string]$act['a']
        $Script:Br['speech'] = New-BrainSpeech ([string]$d[0]) $true
        Write-Output ((Get-BrainSnapshot) | ConvertTo-Json)
    }
    catch {
        Write-Output ("{ ""error"": """ + $_.Exception.Message + """ }")
    }
    exit 0
}


# ────────────── 骨骼渲染器（多帧 + 弹簧） ──────────────
if (-not ('PetRig' -as [type])) {
    Add-Type -TypeDefinition (Get-Content (Join-Path $Root 'PetRig.cs') -Raw -Encoding UTF8) -ReferencedAssemblies System.Drawing
}

# ────────────── 动作帧（站 / 走 / 笑 / 睡 / 看） ──────────────
# 帧清单已在"运行状态"里加载（$Script:FramePaths / $Script:FrameIndex）
$RigSuper = 2.0
$rigPaths = $Script:FramePaths
if ($rigPaths.Count -eq 0) { $rigPaths = @((Resolve-PetPath ([string]$Config['petFile']))) }
$Script:Rig = New-Object PetRig $rigPaths, ([int]$PetH), $RigSuper

function Get-FrameIndex([string]$name) {
    if ($Script:FrameIndex.ContainsKey($name)) { return [int]$Script:FrameIndex[$name] }
    if ($Script:FrameIndex.ContainsKey('open')) { return [int]$Script:FrameIndex['open'] }
    return 0
}

# 眨眼调度
$Script:NextBlinkAt = [DateTime]::Now.AddSeconds(2.5)
$Script:BlinkUntil = [DateTime]::MinValue

# ────────────── 把"状态 + 物理 + 视线"翻译成骨架参数 ──────────────
function Update-RigTargets {
    $state = [string]$Script:Br['state']
    $t = [double]$St['tick']
    $now = [DateTime]::Now

    # 1) 视线：朝鼠标，做饱和避免抖动
    $cx = [double]$Script:CursorXY[0]
    $cy = [double]$Script:CursorXY[1]
    $headCenterX = [double]$St['petX']
    $headCenterY = [double]$St['petY'] - $PetH * 0.78
    $dx = $cx - $headCenterX
    $dy = $cy - $headCenterY
    $gx = 0.0; $gy = 0.0
    if ([Math]::Abs($dx) -gt 8) { $gx = [Math]::Max(-1.0, [Math]::Min(1.0, $dx / 240.0)) }
    if ([Math]::Abs($dy) -gt 8) { $gy = [Math]::Max(-1.0, [Math]::Min(1.0, $dy / 240.0)) }

    # 2) 状态 → 用哪一帧 + 姿态基线
    $frameName = 'open'
    $fadeSec = 0.18
    $lean = 0.0; $lift = 0.0; $squash = 0.0; $bodyRot = 0.0; $headRot = 0.0
    $breathPeriod = 3.6; $breathAmp = 1.0

    switch ($state) {
        'sleeping'    { $frameName = 'sleep'; $fadeSec = 0.45; $lean = 0.16; $headRot = 0.8; $breathPeriod = 5.4; $breathAmp = 0.55 }
        'tired'       { $frameName = 'open';  $fadeSec = 0.30; $lean = 0.12; $headRot = 1.0; $breathPeriod = 4.2; $breathAmp = 0.70 }
        'focused'     { $frameName = 'open';  $fadeSec = 0.25; $headRot = -0.3; $breathPeriod = 3.2; $breathAmp = 0.60 }
        'happy'       { $frameName = 'smile'; $fadeSec = 0.14; $headRot = -0.8; $breathPeriod = 3.0; $breathAmp = 1.15 }
        'alert'       { $frameName = 'smile'; $fadeSec = 0.12; $headRot = -0.6; $breathPeriod = 2.8; $breathAmp = 1.20 }
        'observe'     { $frameName = 'look';  $fadeSec = 0.20; $headRot = -0.2; $breathPeriod = 3.4; $breathAmp = 0.95 }
        'interacting' { $frameName = 'look';  $fadeSec = 0.12; $lean = $gx * 0.45; $breathPeriod = 2.6; $breathAmp = 1.10 }
    }

    # 3) 物理优先：走路 / 被拖动
    if ([bool]$St['walking']) { $frameName = 'walk'; $fadeSec = 0.14 }
    if ([bool]$St['dragging']) { $frameName = 'look'; $fadeSec = 0.10 }

    # 4) 呼吸：连续起伏，不是每帧抖动
    $breath = [Math]::Sin($t * 2 * [Math]::PI / $breathPeriod)
    $lift += $breath * 0.20 * $breathAmp
    $squash += $breath * 0.26 * $breathAmp

    # 5) 视线带动身体（头快、身体慢，相位自然错开）
    $headRot += $gx * 1.3
    $bodyRot += $gx * 0.45
    $lean += $gx * 0.18

    # 6) 物理状态叠加
    if ([bool]$St['falling']) { $squash -= 0.45; $lift -= 0.25 }
    if ([double]$St['jit'] -gt 0) { $lift += [Math]::Sin([Math]::PI * [double]$St['jit']) * 1.1 }
    if ([bool]$St['walking']) {
        $step = [Math]::Abs([Math]::Sin($t * 9.5))
        $lift += $step * 0.30
        $headRot += [Math]::Sin($t * 9.5) * 0.5
    }
    if ([bool]$St['dragging']) {
        $squash += 0.30
        $bodyRot += [Math]::Sin($t * 3.2) * 0.9
    }

    # 7) 眨眼：换成"闭眼笑"帧，短促闪过
    if ($now -ge [DateTime]$Script:NextBlinkAt) {
        $Script:BlinkUntil = $now.AddMilliseconds(130)
        $gap = 2.4 + (Get-Random -Maximum 320) / 100.0
        if ($state -eq 'sleeping') { $gap = 9.0 + (Get-Random -Maximum 400) / 100.0 }
        elseif ($state -eq 'tired') { $gap = 4.5 + (Get-Random -Maximum 300) / 100.0 }
        elseif ($state -eq 'alert') { $gap = 1.6 + (Get-Random -Maximum 180) / 100.0 }
        $Script:NextBlinkAt = $now.AddSeconds($gap)
    }
    if ($now -lt [DateTime]$Script:BlinkUntil -and $state -ne 'sleeping' -and -not [bool]$St['walking']) {
        if ($Script:FrameIndex.ContainsKey('smile')) { $frameName = 'smile'; $fadeSec = 0.05 }
    }

    # 8) 换帧（同一帧不会重复触发）
    $Script:Rig.SetFrame((Get-FrameIndex $frameName), [float]$fadeSec)

    # 9) 朝向交给弹簧平滑过渡
    $turn = [double]$St['flip']

    $Script:Rig.SetTargets(
        [float]$gx, [float]$gy,
        [float]$lean, [float]$lift, [float]$squash, [float]$bodyRot,
        [float]$headRot, [float]$turn
    )
}

# ────────────── 每帧渲染 ──────────────
function Render-Frame([double]$dt) {
    Update-RigTargets
    $Script:Rig.Step([float]$dt)
    # 每次都把位图内容重画一遍，然后强制重绘（否则窗口会停在第一帧）
    $bmp = $Script:Rig.Render()
    $Pet.Image = $null
    $Pet.Image = $bmp
    $Pet.Invalidate()

    # 自检：每 30 帧记录一次渲染结果，确认画面真的在变
    if ([bool]$Script:ProbeRender) {
        $Script:ProbeCount = [int]$Script:ProbeCount + 1
        if (($Script:ProbeCount % 30) -eq 0) {
            try {
                $ms = New-Object System.IO.MemoryStream
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $hash = [BitConverter]::ToString($sha.ComputeHash($ms.ToArray())).Replace('-', '').Substring(0, 10)
                $sha.Dispose(); $ms.Dispose()
                $line = "frame=$($Script:ProbeCount) hash=$hash rigFrame=$($Script:Rig.CurrentFrame) tick=$([Math]::Round([double]$St['tick'],2)) turn=$([Math]::Round([double]$Script:Rig.Turn,3)) walking=$([bool]$St['walking']) flip=$([Math]::Round([double]$St['flip'],1)) petX=$([Math]::Round([double]$St['petX'])) petY=$([Math]::Round([double]$St['petY'])) state=$([string]$Script:Br['state'])"
                [System.IO.File]::AppendAllText((Join-Path $Root 'render_probe.log'), "$([DateTime]::Now.ToString('HH:mm:ss')) $line`r`n")
            }
            catch { }
        }
    }
}
# ────────────── 让大脑决定"要不要溜达" ──────────────
function Start-BrainWander {
    # 在"自己所在的那块屏"上溜达，而不是死守主屏
    # 只在"指定的那块屏"上溜达
    $screen = $Wa
    $margin = 30
    $minX = [double]($screen.Left + $margin + $PetW / 2)
    $maxX = [double]($screen.Right - $margin - $PetW / 2)
    if ($maxX -le $minX) { return }
    $curX = [double]$St['petX']
    $reach = [Math]::Max(120.0, [Math]::Min($screen.Width / 3.0, 420.0))
    $lo = [Math]::Max($minX, $curX - $reach)
    $hi = [Math]::Min($maxX, $curX + $reach)
    if (($hi - $lo) -lt 40) { $lo = $minX; $hi = $maxX }
    $span = [int]($hi - $lo)
    if ($span -lt 2) { $span = 2 }
    $St['walkTargetX'] = [double]($lo + (Get-Random -Maximum $span))
    $groundY = $screen.Bottom - (Get-Random -Maximum 40)
    $groundMin = [double]($screen.Top + $PetH * 1.1)
    if ($groundY -lt $groundMin) { $groundY = [int]$groundMin }
    $St['walkTargetY'] = [double]$groundY
    $St['walking'] = $true
    $St['walkBeganAt'] = Get-Date
}

function Show-Speech([string]$text) {
    if (-not [bool]$Config['speech'] -or -not $text) { return }
    $tmp = $null
    try {
        $tmp = [DeskPet.Win]::RenderText($text, $FontName, 15, 460, 300)
        $fs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $img = [System.Drawing.Image]::FromStream($fs)
        if ($Bubble.Image) { $Bubble.Image.Dispose() }
        $Bubble.Image = $img
        $Bubble.Size = New-Object System.Drawing.Size ([int]$img.Width), ([int]$img.Height)
        $Bubble.Visible = $true
        $Bubble.BringToFront()
        $Script:BubbleUntil = [DateTime]::Now.AddMilliseconds([double]$Config['bubbleMs'])
        Layout-Frame
    }
    catch { }
    finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Layout-Frame {
    # 窗口尺寸固定（所有形变都在渲染器内部完成），只在真的变了才改大小/移动，
    # 避免每帧 SetWindowPos 造成闪烁。但宠物的位置每次都重算——
    # 否则气泡出现时宠物不会下移，气泡就会盖住它的脸。
    $pw = [int]$PetW
    $ph = [int]$PetH

    $bubH = 0; $bubW = 0
    if ($Bubble.Visible) { $bubH = $Bubble.Height; $bubW = $Bubble.Width }

    $gap = 14                                   # 气泡与头顶之间留的空隙
    $winW = [int][Math]::Max($pw, $bubW)
    $winH = [int]($bubH + $gap + $ph + 6)

    if ([int]$St['lastWinW'] -ne $winW -or [int]$St['lastWinH'] -ne $winH) {
        $Form.Size = New-Object System.Drawing.Size $winW, $winH
        $St['lastWinW'] = $winW
        $St['lastWinH'] = $winH
    }
    if ([int]$St['lastPetH'] -ne $ph) {
        $Pet.Size = New-Object System.Drawing.Size $pw, $ph
        $St['lastPetH'] = $ph
    }

    # 宠物永远在气泡下方
    $petX = [int](($winW - $pw) / 2)
    $petY = [int]($bubH + $gap)
    if ($Pet.Left -ne $petX -or $Pet.Top -ne $petY) {
        $Pet.Location = New-Object System.Drawing.Point $petX, $petY
    }
    if ($Bubble.Visible) {
        $bubbleX = [int](($winW - $bubW) / 2)
        if ($Bubble.Left -ne $bubbleX -or $Bubble.Top -ne 0) {
            $Bubble.Location = New-Object System.Drawing.Point $bubbleX, 0
        }
    }

    $winX = [int][Math]::Round([double]$St['petX'] - $winW / 2.0)
    # petY 是"脚底"位置；窗口顶 = 脚底 - 窗口高 + 底部留白(6)
    $winY = [int][Math]::Round([double]$St['petY'] - $winH + 6)
    if ($Form.Left -ne $winX -or $Form.Top -ne $winY) {
        $Form.Location = New-Object System.Drawing.Point $winX, $winY
    }
}

function Enter-Action([string]$name, [int]$ms, $frames, [int]$frameMs) {
    $St['actionName'] = $name
    $St['actionFrames'] = @($frames)
    $St['actionFrameMs'] = if ($frameMs -gt 0) { $frameMs } else { 120 }
    $St['actionUntil'] = [DateTime]::Now.AddMilliseconds($ms)
    $St['lastFrameAt'] = [DateTime]::MinValue
}

# ────────────────────────────── 主循环 ──────────────────────────────
function Tick {
    $now = [DateTime]::Now
    $dt = ($now - $Script:LastNow).TotalMilliseconds / 1000.0
    $Script:LastNow = $now
    if ($dt -le 0.001) { $dt = 0.001 }
    if ($dt -gt 0.15) { $dt = 0.15 }
    $St['tick'] = [double]$St['tick'] + $dt
    $t = [double]$St['tick']

    $ok = [DeskPet.Win]::GetCursor($Script:CursorXY)
    $cx = [double]$Script:CursorXY[0]
    $cy = [double]$Script:CursorXY[1]
    if (-not $ok) { $cx = [double]$St['petX']; $cy = [double]$St['petY'] }

    $reduce = [bool]$Config['reduceMotion']
    $weight = [double]$Config['weight']
    if ($weight -lt 0.35) { $weight = 0.35 }
    if ($weight -gt 0.85) { $weight = 0.85 }

    # ---------- 拖动 ----------
    if ([bool]$St['dragging']) {
        $px = $cx - [double]$St['grabX']
        $py = $cy - [double]$St['grabY']
        $St['draggingVel'] = 0.6 * [double]$St['draggingVel'] + 0.4 * ($px - [double]$St['petX'])
        $St['draggingVelY'] = 0.6 * [double]$St['draggingVelY'] + 0.4 * ($py - [double]$St['petY'])
        $St['petX'] = $px
        $St['petY'] = $py
        $St['idleTime'] = 0.0
        $St['draggingIdle'] = [double]$St['draggingIdle'] + $dt
        if ([double]$St['draggingIdle'] -gt 0.25) {
            # 被拎住：轻轻上下晃
            $St['lift'] = 3.0 + [Math]::Sin($t * 4.2) * 3.0
        }
        else {
            $St['lift'] = 0.0
        }
        # 拎得快时"风速拉伸"；停住时不再挤压，避免频繁换窗口尺寸导致闪屏
        $vlen = [Math]::Sqrt([double]$St['draggingVel'] * [double]$St['draggingVel'] + [double]$St['draggingVelY'] * [double]$St['draggingVelY'])
        $St['squashY'] = 1.0 + [Math]::Min(0.28, $vlen * 0.03)
        $St['actionName'] = ''
        Render-Frame $dt
        Layout-Frame
        return
    }

    # ---------- 下落 ----------
    if ([bool]$St['falling']) {
        $St['fallVelY'] = [double]$St['fallVelY'] + 2000 * $dt
        $St['petX'] = [double]$St['petX'] + [double]$St['fallVelX'] * $dt
        $St['petY'] = [double]$St['petY'] + [double]$St['fallVelY'] * $dt
        $St['fallVelX'] = [double]$St['fallVelX'] * 0.985
        $St['lift'] = 0.0
        $St['squashY'] = 1.0
        if ([double]$St['petY'] -ge [double]$St['restY']) {
            $St['petY'] = [double]$St['restY']
            $St['falling'] = $false
            $St['jit'] = 1.0
            $St['squashY'] = 0.80          # 落地瞬间压扁一下
            $St['idleTime'] = 0.0
            if ($HappyFrames.Count -gt 0) { Enter-Action 'happy' 420 $HappyFrames 110 }
            $hl = @($Config['happyLines'])
            if ($hl.Count -gt 0 -and (Get-Random -Maximum 100) -lt (35 * $weight)) { Show-Speech ($hl | Get-Random) }
        }
        Render-Frame $dt
        Layout-Frame
        return
    }

    # ---------- 待机 / 行走 ----------
    $St['idleTime'] = [double]$St['idleTime'] + $dt
    $walk = [bool]$St['walking']
    if ($walk) {
        $tx = [double]$St['walkTargetX']
        $petX = [double]$St['petX']
        $ty = [double]$St['walkTargetY']
        if ($ty -le 0) { $ty = [double]$St['restY'] }
        $petY = [double]$St['petY']
        $dir = if ($tx -gt $petX) { 1.0 } else { -1.0 }
        $step = [double]$St['walkSpeed'] * 60 * $dt
        $petX = $petX + $dir * $step
        # Y 轴缓慢靠拢，避免宠物突然上下跳
        if ([Math]::Abs($ty - $petY) -gt 1) {
            $petY = $petY + [Math]::Sign($ty - $petY) * [Math]::Min([Math]::Abs($ty - $petY), $step * 0.45)
        }
        $St['petX'] = $petX
        $St['petY'] = $petY
        $St['restX'] = $petX
        $St['restY'] = $petY
        $St['flip'] = $dir
        # 走路的步态由渲染器负责（小碎步 + 头部轻点头），这里只更新位置
        if ([Math]::Abs($petX - $tx) -lt 4) {
            $St['walking'] = $false
            $St['actionName'] = ''
            $seg = [int][Math]::Max(8, 26 * (1.4 - $weight))
            $St['nextWander'] = $now.AddSeconds((Get-Random -Maximum $seg) + 8)
        }
    }

    # 鼠标距离：供大脑判断"是否靠近"
    $centerX = [double]$St['petX']
    $centerY = [double]$St['petY'] - $PetH / 2
    $dxc = $cx - $centerX
    $dyc = $cy - $centerY
    $dist = [Math]::Sqrt($dxc * $dxc + $dyc * $dyc)
    $St['dist'] = $dist
    if ($dist -lt $PetW * 0.62 -and -not $walk -and ($now - $Script:LastTickle).TotalSeconds -gt 4) {
        $Script:LastTickle = $now
        $St['jit'] = [Math]::Max([double]$St['jit'], 0.9)
        try { Send-BrainEvent 'pet' } catch { }
    }

    # 跳跃余量（渲染器会把它换算成位移）
    if ([double]$St['jit'] -gt 0) {
        $St['jit'] = [Math]::Max(0.0, [double]$St['jit'] - $dt * 2.2)
    }

    # ══════════════ 大脑：感知 → 决策 → 表达 ══════════════
    try { Invoke-BrainTick $dt } catch { }

    # 大脑决定"去溜达"时才走
    if ([string]$Script:Br['action'] -eq 'follow_desktop' -and -not $walk -and -not $reduce -and -not [bool]$St['walking']) {
        Start-BrainWander
    }

    if ($Bubble.Visible -and $now -gt $Script:BubbleUntil) { $Bubble.Visible = $false }

    # 别跑出屏幕外（比如被甩到屏幕边缘之外）
    # 别跑出整个桌面（多显示器时允许待在任何一块屏上）
    # 只允许待在指定的那块屏里（避免跑到看不见的屏幕）
    $scr = $Wa
    $px = [double]$St['petX']
    $py = [double]$St['petY']
    if ($px -lt $scr.Left + $PetW / 2.0) { $px = $scr.Left + $PetW / 2.0 }
    if ($px -gt $scr.Right - $PetW / 2.0) { $px = $scr.Right - $PetW / 2.0 }
    if ($py -lt $scr.Top + $PetH) { $py = $scr.Top + $PetH }
    if ($py -gt $scr.Bottom) { $py = $scr.Bottom }
    $St['petX'] = $px
    $St['petY'] = $py
    if ([double]$St['restY'] -gt $scr.Bottom) { $St['restY'] = [double]$scr.Bottom }

    Render-Frame $dt
    Layout-Frame
}

# 全局异常钩子：任何逃出事件回调的异常都记下来，并阻止弹出模态框卡死消息循环
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
            param($s, $e)
            try {
                [System.IO.File]::AppendAllText((Join-Path $Root 'crash.log'),
                    "$([DateTime]::Now.ToString('HH:mm:ss')) THREAD: $($e.Exception.Message)`r`n$($e.Exception.StackTrace)`r`n")
            }
            catch { }
        })
}
catch { }

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 33
$Timer.Add_Tick({
        try { Tick }
        catch {
            if ([bool]$Script:LogErrors) {
                try { [System.IO.File]::AppendAllText((Join-Path $Root 'tick_error.log'), "$([DateTime]::Now.ToString('HH:mm:ss')) $($_.Exception.Message) @line $($_.InvocationInfo.ScriptLineNumber)`r`n") } catch { }
            }
        }
    })

# ────────────────────────────── 鼠标交互 ──────────────────────────────
function Start-Press {
    if ([bool]$Config['locked']) { return }
    $mx = [System.Windows.Forms.Cursor]::Position.X
    $my = [System.Windows.Forms.Cursor]::Position.Y
    $St['pressed'] = $true
    $St['pressX'] = $mx
    $St['pressY'] = $my
    $St['grabX'] = $mx - [double]$St['petX']
    $St['grabY'] = $my - [double]$St['petY']
}

function Update-Drag {
    if (-not [bool]$St['pressed']) { return }
    $mx = [System.Windows.Forms.Cursor]::Position.X
    $my = [System.Windows.Forms.Cursor]::Position.Y
    $moved = [Math]::Sqrt([Math]::Pow($mx - [int]$St['pressX'], 2) + [Math]::Pow($my - [int]$St['pressY'], 2))
    if (-not [bool]$St['dragging'] -and $moved -gt 6) {
        $St['dragging'] = $true
        $St['draggingIdle'] = 0.0
        $St['draggingVel'] = 0.0
        $St['draggingVelY'] = 0.0
        $St['walking'] = $false
        $St['spin'] = 0.0
        try { Send-BrainEvent 'drag' } catch { }
    }
}

function End-Press {
    if (-not [bool]$St['pressed']) { return }
    $wasDragging = [bool]$St['dragging']
    $St['pressed'] = $false
    $St['dragging'] = $false
    if ($wasDragging) {
        # 松手：保留甩出的惯性，然后落回松手处的地面
        $St['falling'] = $true
        $St['fallVelX'] = [double]$St['draggingVel'] * 0.5
        $St['fallVelY'] = [Math]::Min(0.0, [double]$St['draggingVelY'])
        $St['restX'] = [double]$St['petX']
        $St['restY'] = [double]$St['petY']
        $St['lift'] = 0.0
        try { Send-BrainEvent 'drop' } catch { }
    }
    else {
        $now = [DateTime]::Now
        $isDouble = ($now - $Script:LastClick).TotalMilliseconds -lt 400
        $Script:LastClick = $now
        $St['jit'] = 1.0
        if ($HappyFrames.Count -gt 0) { Enter-Action 'happy' 560 $HappyFrames 110 }
        # 交给大脑决定说什么（不再随机取 happyLines）
        try { Send-BrainEvent 'click' } catch { }
        if ($isDouble) { try { Send-BrainEvent 'pet' } catch { } }
    }
}

$Pet.Add_MouseDown({ Start-Press })
$Form.Add_MouseDown({ Start-Press })
$Pet.Add_MouseMove({ Update-Drag })
$Form.Add_MouseMove({ Update-Drag })
$Pet.Add_MouseUp({ End-Press })
$Form.Add_MouseUp({ End-Press })

# 拖入图片 → 直接换形象
function Handle-Drop($e) {
    if ($e.Data -and $e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if ($files -and $files.Count -gt 0) { Switch-Pet $files[0] }
    }
}
$Form.AllowDrop = $true
$Pet.AllowDrop = $true
$Form.Add_DragEnter({ if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$Pet.Add_DragEnter({ if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$Form.Add_DragDrop({ param($sender, $e) Handle-Drop $e })
$Pet.Add_DragDrop({ param($sender, $e) Handle-Drop $e })

# ────────────────────────────── 换形象 / 大小 ──────────────────────────────
function Get-ActiveFramePaths {
    # 优先用 assets\frames 下的多帧；没有就退回单张形象
    if ($Script:FramePaths -and $Script:FramePaths.Count -gt 0) { return , $Script:FramePaths }
    return , @((Resolve-PetPath ([string]$Config['petFile'])))
}

function New-PetRig([int]$height) {
    if ($Script:Rig) { try { $Script:Rig.Dispose() } catch { } }
    $paths = Get-ActiveFramePaths
    $Script:Rig = New-Object PetRig $paths, $height, $RigSuper
    $St['lastPetH'] = -1
    $St['lastWinW'] = 0
    $St['lastWinH'] = 0
}

# 帧比例（宽/高），用于算窗口宽度
function Get-FrameAspect {
    try {
        $fp = (Get-ActiveFramePaths)[0]
        $img = [System.Drawing.Image]::FromFile($fp)
        $a = [double]$img.Width / [double]$img.Height
        $img.Dispose()
        return $a
    }
    catch { return 322.0 / 450.0 }
}

function Apply-Scale {
    $Script:PetH = [int][Math]::Max(40, [Math]::Round(132 * [double]$Config['size']))
    $Script:PetW = [int][Math]::Max(20, [Math]::Round($Script:PetH * (Get-FrameAspect)))
    New-PetRig $Script:PetH
    $St['restY'] = [Math]::Min([double]$St['restY'], [double]$St['petY'])
    Layout-Frame
}

function Switch-Pet([string]$file) {
    $set = Load-Set $file
    if (-not $set['valid']) { return }
    $Config['petFile'] = $file
    Save-Config $Config

    $Script:BaseFrames = @($set['frames'])
    $Script:BaseW = [double]$Script:BaseFrames[0].Width
    $Script:BaseH = [double]$Script:BaseFrames[0].Height
    $maxDim = Get-MaxFrame @($Script:BaseFrames, $BlinkFrames, $HappyFrames, $WalkFrames)
    $Script:MaxFrameW = [double]$maxDim['w']
    $Script:MaxFrameH = [double]$maxDim['h']
    $St['actionName'] = ''
    $St['frameIndex'] = 0
    if ($Bubble.Image) { $Bubble.Image.Dispose(); $Bubble.Image = $null }
    $Bubble.Visible = $false
    Apply-Scale
    Show-Speech '我换新衣服啦！'
}

# ────────────────────────────── 右键菜单 ──────────────────────────────
function Build-Menu {
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $m.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $m.ShowImageMargin = $false

    $say = $m.Items.Add('让它说句话')
    $say.Add_Click({
            # 让它按当前状态说一句（由大脑生成，不是随机贴台词）
            $line = New-BrainSpeech ([string]$Script:Br['state']) $true
            if ($line) { Show-Speech $line }
        })

    $mind = $m.Items.Add('它在想什么？')
    $mind.Add_Click({
            $txt = Get-BrainDebugText
            $who = '桌宠'
            try { if ($Script:Persona -and $Script:Persona.name) { $who = [string]$Script:Persona.name } } catch { }
            [System.Windows.Forms.MessageBox]::Show($txt, "$who 的内心", 'OK', 'Information') | Out-Null
        })

    $comeHere = $m.Items.Add('挪到我面前')
    $comeHere.Add_Click({
            try {
                $cur = [System.Windows.Forms.Cursor]::Position
                $scr = [System.Windows.Forms.Screen]::FromPoint($cur).WorkingArea
                $tx = [double]$cur.X + 40
                $ty = [double]$cur.Y + 40
                $tx = [Math]::Max($scr.Left + $PetW / 2, [Math]::Min($scr.Right - $PetW / 2, $tx))
                $ty = [Math]::Max($scr.Top + $PetH, [Math]::Min($scr.Bottom - 4, $ty))
                $St['petX'] = $tx
                $St['petY'] = $ty
                $St['restX'] = $tx
                $St['restY'] = $ty
                $St['walking'] = $false
                $St['falling'] = $false
                Layout-Frame
                Show-Speech '来了来了。'
            }
            catch { }
        })

    $screenMenu = $m.Items.Add('显示在哪块屏')
    foreach ($opt in @(
            @{ t = '小屏'; v = 'small' },
            @{ t = '大屏'; v = 'large' },
            @{ t = '主屏'; v = 'primary' },
            @{ t = '跟着鼠标'; v = 'auto' })) {
        $it = $screenMenu.DropDownItems.Add($opt['t'])
        $it.Tag = $opt['v']
        $it.Checked = ([string]$Config['screen'] -eq [string]$opt['v'])
        $it.Add_Click({
                param($sender, $ev)
                $Config['screen'] = [string]$sender.Tag
                Save-Config $Config
                $newScreen = Get-TargetScreen
                $wa2 = $newScreen.WorkingArea
                $St['petX'] = [double]($wa2.Right - $PetW / 2 - 40)
                $St['petY'] = [double]($wa2.Bottom - 8)
                $St['restX'] = [double]$St['petX']
                $St['restY'] = [double]$St['petY']
                $St['walking'] = $false
                $St['falling'] = $false
                $Script:Wa = $wa2
                Layout-Frame
                Show-Speech '我搬到这块屏了。'
            })
    }

    $happy = $m.Items.Add('开心一下')
    $happy.Add_Click({
            $St['jit'] = 1.0
            if ($HappyFrames.Count -gt 0) { Enter-Action 'happy' 620 $HappyFrames 110 }
            try { Send-BrainEvent 'pet' } catch { }
        })

    $size = $m.Items.Add('大小')
    $curSize = [double]$Config['size']
    foreach ($opt in @(@{ t = '小'; v = 0.7 }, @{ t = '中'; v = 1.0 }, @{ t = '大'; v = 1.4 }, @{ t = '特大'; v = 2.0 })) {
        $it = $size.DropDownItems.Add($opt['t'])
        $it.Tag = $opt['v']
        $it.Checked = ([Math]::Abs($curSize - [double]$opt['v']) -lt 0.01)
        $it.Add_Click({
                param($sender, $ev)
                $Config['size'] = [double]$sender.Tag
                Save-Config $Config
                Apply-Scale
                Show-Speech '这个大小可以吗？'
            })
    }

    $chat = $m.Items.Add('话少一点')
    $chat.CheckOnClick = $true
    $chat.Checked = ([double]$Config['idleChatter'] -le 0)
    $chat.Add_Click({
            param($sender, $ev)
            if ($sender.Checked) { $Config['idleChatter'] = 0; $Script:Br['quiet'] = $true }
            else { $Config['idleChatter'] = 45; $Script:Br['quiet'] = $false }
            Save-Config $Config
        })

    $top = $m.Items.Add('总在最前')
    $top.CheckOnClick = $true
    $top.Checked = [bool]$Config['alwaysTop']
    $top.Add_Click({
            param($sender, $ev)
            $Config['alwaysTop'] = [bool]$sender.Checked
            $Form.TopMost = [bool]$sender.Checked
            try { [DeskPet.Win]::SetTopmost($Form.Handle, [bool]$sender.Checked) } catch { }
            Save-Config $Config
        })

    $lock = $m.Items.Add('锁定位置')
    $lock.CheckOnClick = $true
    $lock.Checked = [bool]$Config['locked']
    $lock.Add_Click({
            param($sender, $ev)
            $Config['locked'] = [bool]$sender.Checked
            Save-Config $Config
        })

    $m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    $pick = $m.Items.Add('换形象…')
    $pick.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = '选择桌宠形象'
            $dlg.Filter = '图片|*.png;*.gif;*.jpg;*.jpeg;*.bmp;*.ico|所有文件|*.*'
            if ($dlg.ShowDialog() -eq 'OK') { Switch-Pet $dlg.FileName }
        })

    $openDir = $m.Items.Add('打开素材目录')
    $openDir.Add_Click({ Start-Process -FilePath $AssetDir })

    $m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $bye = $m.Items.Add('退出')
    $bye.Add_Click({
            $Timer.Stop()
            try { Save-BrainMemory } catch { }
            if ($Bubble.Image) { $Bubble.Image.Dispose() }
            $Form.Close()
            [System.Windows.Forms.Application]::Exit()
        })
    return $m
}

$Menu = Build-Menu
$Form.ContextMenuStrip = $Menu
$Pet.ContextMenuStrip = $Menu

# 关窗时也保存记忆（点 X / 系统关机都覆盖到）
$Form.Add_FormClosing({
        try { Save-BrainMemory } catch { }
    })

# 开机问候：按时间与"多久没见"决定第一句话
$Form.Add_Shown({
        # 启动顺序：不抢焦点 → 定位 → 问候 → 先画一帧 → 开定时器
        try { [DeskPet.Win]::NoActivate($Form.Handle) } catch { }
        if ([bool]$Config['alwaysTop']) { try { [DeskPet.Win]::SetTopmost($Form.Handle, $true) } catch { } }

        try { Layout-Frame } catch { }
        try { Render-Frame 0.033 } catch { }

        try {
            $slot = Get-TimeSlot
            $lines = @(Get-PersonaLines 'timeLines' $slot)
            if ($lines.Count -eq 0) { $lines = @(Get-PersonaLines 'speech' 'idle') }
            $hello = Select-Line $lines
            if ($hello) { Show-Speech $hello }
        }
        catch { }

        try { Tick } catch { }
        $Timer.Start()
    })

if ($AutoCloseAfter) {
    $CloseTimer = New-Object System.Windows.Forms.Timer
    $CloseTimer.Interval = [Math]::Max(800, $Seconds * 1000)
    $CloseTimer.Add_Tick({
            $CloseTimer.Stop()
            $Timer.Stop()
            $Form.Close()
            [System.Windows.Forms.Application]::Exit()
        })
    $CloseTimer.Start()
}

[System.Windows.Forms.Application]::Run($Form)
