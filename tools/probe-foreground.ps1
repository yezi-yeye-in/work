# 探测：当前前台窗口 + 应用分类
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\EDY\Documents\deepseek-harness\default-workspace\deskpet'
$Root = $root
$St = @{ dragging = $false; pressed = $false; dist = 9999.0; petX = 0.0; petY = 0.0 }
$Bubble = [pscustomobject]@{ Visible = $false }
function Show-Speech([string]$t) { }
. (Join-Path $root 'pet.brain.ps1')

$fg = [PetBrain.Native]::Foreground()
$proc = [string]$fg[0]
$title = [string]$fg[1]
$cls = ''
if ($fg.Length -ge 4) { $cls = [string]$fg[3] }
$kind = Get-AppKind $proc $title $cls
Write-Host "进程名   : '$proc'"
Write-Host "窗口类名 : '$cls'"
Write-Host "窗口标题 : '$title'"
Write-Host "分类     : $kind"
Write-Host "空闲秒数 : $([Math]::Round([PetBrain.Native]::IdleSeconds(),1))"