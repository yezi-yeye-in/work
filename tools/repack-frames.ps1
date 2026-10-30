# repack-frames.ps1 —— 把 assets 下的立绘重新处理成对齐的动作帧
#
# 用法（在本文件夹地址栏输入 powershell 回车，然后）：
#   .\repack-frames.ps1
#
# 会做四件事：
#   1. 从四边泛洪去背景（适合浅灰渐变底）
#   2. 清掉被包住的浅色小残块、羽化边缘
#   3. 取所有帧的并集包围盒统一裁剪（保证帧之间对位不跳）
#   4. 等比缩放到统一高度，输出到 assets\frames\
#
# 帧来源（存在哪个就处理哪个）：
#   assets\chibi_source.png  -> open
#   assets\frame_walk.png    -> walk
#   assets\frame_smile.png   -> smile
#   assets\frame_sleep.png   -> sleep
#   assets\frame_look.png    -> look

[CmdletBinding()]
param(
    [int]$TargetHeight = 620,
    [int]$WorkHeight = 1000,
    [int]$Tolerance = 26,
    [switch]$NoPatchCursor
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$assetDir = Join-Path $root 'assets'
$outDir = Join-Path $assetDir 'frames'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

if (-not ('FramePrep' -as [type])) {
    Add-Type -TypeDefinition (Get-Content (Join-Path $root 'FramePrep.cs') -Raw -Encoding UTF8) -ReferencedAssemblies System.Drawing
}

$map = @(
    @{ name = 'open'; file = 'chibi_source.png' },
    @{ name = 'walk'; file = 'frame_walk.png' },
    @{ name = 'smile'; file = 'frame_smile.png' },
    @{ name = 'sleep'; file = 'frame_sleep.png' },
    @{ name = 'look'; file = 'frame_look.png' }
)

$paths = @()
$names = @()
foreach ($m in $map) {
    $fp = Join-Path $assetDir $m.file
    if (Test-Path -LiteralPath $fp) {
        $paths += $fp
        $names += $m.name
    }
}

if ($paths.Count -eq 0) {
    Write-Host 'assets 里没有找到任何帧源文件，什么也没做。'
    exit 1
}

Write-Host ("处理 {0} 帧: {1}" -f $paths.Count, ($names -join ', '))
$patch = -not $NoPatchCursor
$result = [FramePrep]::Run($paths, $names, $outDir, $TargetHeight, $WorkHeight, $Tolerance, $patch)
Write-Host $result
Write-Host ''
Write-Host "完成。输出目录：$outDir"
Write-Host '重启桌宠（或右键 → 退出后重新双击「启动桌宠.lnk」）即可看到新帧。'
