# make-pet.ps1 —— 把一张人像/照片做成桌宠形象（两种风格）
#
# 用法（在本文件夹地址栏输入 powershell 回车，然后）：
#   .\make-pet.ps1 -In assets\source.jpg                     # 默认：贴纸风格，高 240px
#   .\make-pet.ps1 -In assets\source.jpg -Mode sticker -Height 100   # 搜狗那种小桌宠
#   .\make-pet.ps1 -In assets\source.jpg -Mode circle -Size 180      # 圆形头像
#
# 参数：
#   -In       原图（jpg/png/bmp/gif）
#   -Out      输出路径，默认 assets\pet.png
#   -Mode     sticker（圆角贴纸，默认）| circle（圆形头像）
#   -Height   [sticker] 输出高度像素
#   -Size     [circle]  输出边长像素
#   -TopCrop  [sticker] 顶部裁掉比例（默认 0.06，去掉多余头顶空白）
#   -BottomCrop [sticker] 底部裁掉比例（默认 0.18）
#   -Radius   [sticker] 圆角半径，默认 26
#   -FaceY    [circle]  取景中心高度比例，默认 0.40

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$In,
    [string]$Out,
    [ValidateSet('sticker', 'circle')][string]$Mode = 'sticker',
    [int]$Height = 240,
    [int]$Size = 260,
    [double]$TopCrop = 0.06,
    [double]$BottomCrop = 0.18,
    [int]$Radius = 26,
    [double]$FaceY = 0.40,
    [int]$Ring = 1
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$srcPath = (Resolve-Path -LiteralPath $In).Path
if (-not $Out) { $Out = [System.IO.Path]::Combine($PSScriptRoot, 'assets', 'pet.png') }
$outDir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$cs = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class PetMaker {
    // 圆角/圆形贴纸：裁剪 + 圆角 + 白色描边
    public static string Sticker(string inPath, string outPath, int targetHeight, double topCrop, double botCrop, int radius) {
        using (var src0 = new Bitmap(inPath)) {
            int srcH = src0.Height;
            int srcW = src0.Width;
            int cutTop = (int)Math.Round(srcH * topCrop);
            int cutBot = (int)Math.Round(srcH * botCrop);
            int cropH = srcH - cutTop - cutBot;
            if (cropH < 20) { cropH = srcH; cutTop = 0; }
            int cropW = srcW;

            double scale = (double)targetHeight / cropH;
            int cw = Math.Max(8, (int)Math.Round(cropW * scale));
            int ch = Math.Max(8, (int)Math.Round(cropH * scale));

            var baseBmp = new Bitmap(cw, ch, PixelFormat.Format32bppArgb);
            using (var gb = Graphics.FromImage(baseBmp)) {
                gb.InterpolationMode = InterpolationMode.HighQualityBicubic;
                gb.PixelOffsetMode = PixelOffsetMode.HighQuality;
                gb.DrawImage(src0, new Rectangle(0, 0, cw, ch), new Rectangle(0, cutTop, cropW, cropH), GraphicsUnit.Pixel);
            }

            int r = Math.Min(radius, Math.Min(cw, ch) / 3);
            var path = RoundRect(cw, ch, r);
            var img = new Bitmap(cw, ch, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(img)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.Clear(Color.Transparent);
                int ringW = Math.Max(3, (int)Math.Round(ch * 0.035));   // 白描边宽度随尺寸缩放
                if (ringW > 0) {
                    using (var pen = new Pen(Color.FromArgb(255, 255, 255, 255), ringW)) {
                        pen.LineJoin = LineJoin.Round;
                        var outline = new GraphicsPath();
                        outline.AddPath(path, false);
                        g.DrawPath(pen, outline);
                        outline.Dispose();
                    }
                }
                g.SetClip(path);
                g.DrawImage(baseBmp, new Rectangle(0, 0, cw, ch), new Rectangle(0, 0, cw, ch), GraphicsUnit.Pixel);
                g.ResetClip();
            }
            img.Save(outPath, ImageFormat.Png);
            img.Dispose();
            path.Dispose();
            baseBmp.Dispose();
            return "ok " + outPath + " " + cw + "x" + ch + " (贴纸)";
        }
    }

    // 圆形头像
    public static string Circle(string inPath, string outPath, int size, double faceY, int ring) {
        using (var src = new Bitmap(inPath)) {
            int side = (int)Math.Min(src.Width, src.Height * 0.92);
            int cx = src.Width / 2;
            int cy = (int)(src.Height * faceY);
            int sx = Math.Max(0, cx - side / 2);
            int sy = Math.Max(0, cy - side / 2);
            if (sx + side > src.Width) sx = src.Width - side;
            if (sy + side > src.Height) sy = src.Height - side;

            var img = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(img)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.Clear(Color.Transparent);
                var path = new GraphicsPath();
                path.AddEllipse(0, 0, size - 1, size - 1);
                if (ring > 0) {
                    using (var pen = new Pen(Color.FromArgb(232, 255, 255, 255), Math.Max(2f, size / 70f))) {
                        g.DrawPath(pen, path);
                    }
                }
                g.SetClip(path);
                g.DrawImage(src, new Rectangle(0, 0, size, size), new Rectangle(sx, sy, side, side), GraphicsUnit.Pixel);
                g.ResetClip();
                path.Dispose();
            }
            img.Save(outPath, ImageFormat.Png);
            img.Dispose();
            return "ok " + outPath + " " + size + "x" + size + " (圆形头像)";
        }
    }

    static GraphicsPath RoundRect(int w, int h, int r) {
        var p = new GraphicsPath();
        p.AddArc(0, 0, r * 2, r * 2, 180, 90);
        p.AddArc(w - r * 2 - 1, 0, r * 2, r * 2, 270, 90);
        p.AddArc(w - r * 2 - 1, h - r * 2 - 1, r * 2, r * 2, 0, 90);
        p.AddArc(0, h - r * 2 - 1, r * 2, r * 2, 90, 90);
        p.CloseFigure();
        return p;
    }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Drawing

if ($Mode -eq 'circle') {
    if ($Size -lt 32) { $Size = 32 }
    $res = [PetMaker]::Circle($srcPath, $Out, $Size, $FaceY, $Ring)
}
else {
    if ($Height -lt 40) { $Height = 40 }
    if ($Height -gt 800) { $Height = 800 }
    $res = [PetMaker]::Sticker($srcPath, $Out, $Height, $TopCrop, $BottomCrop, $Radius)
}
Write-Host $res
Write-Host '完成！双击「启动桌宠.lnk」即可看到新形象（正在运行时右键 →「换形象」也行）。'
