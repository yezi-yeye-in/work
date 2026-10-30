# 大脑单元测试：伪造环境信号，验证状态机与说话生成
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\EDY\Documents\deepseek-harness\default-workspace\deskpet'
$Root = $root

# 伪造界面对象
$St = @{ dragging = $false; pressed = $false; dist = 9999.0; petX = 1000.0; petY = 600.0 }
$Bubble = [pscustomobject]@{ Visible = $false }
function Show-Speech([string]$t) { $script:lastShown = $t }

. (Join-Path $root 'pet.brain.ps1')

$fail = 0
function Check($name, $expected, $actual, $detail) {
    if ($actual -eq $expected) { Write-Host "PASS  $name  -> $actual   ($detail)" }
    else { $script:fail++; Write-Host "FAIL  $name  期望 $expected 实际 $actual   ($detail)" }
}

function Scenario([double]$idle, [string]$kind, [double]$dist, [bool]$dragging, [double]$energy, [string]$pending, [double]$away = 0.0) {
    $Script:Br['idleSeconds'] = $idle
    $Script:Br['fgKind'] = $kind
    $Script:Br['energy'] = $energy
    $Script:Br['pendingEvent'] = $pending
    $Script:Br['awaySeconds'] = $away
    $St['dragging'] = $dragging
    $St['pressed'] = $false
    $St['dist'] = $dist
    $Bubble.Visible = $false
    return (Get-DesiredState)[0]
}

Write-Host '--- 状态机 ---'
Check '被拖动' 'interacting' (Scenario 0 'work' 9999 $true 1.0 '') 'dragging=true'
Check '深度空闲→睡' 'sleeping' (Scenario 400 'neutral' 9999 $false 1.0 '') 'idle=400s'
Check '中等空闲→困' 'tired' (Scenario 120 'neutral' 9999 $false 1.0 '') 'idle=120s'
Check '精力耗尽→困' 'tired' (Scenario 5 'neutral' 9999 $false 0.15 '') 'energy=0.15'
Check '工作→专注' 'focused' (Scenario 10 'work' 9999 $false 1.0 '') 'kind=work'
Check '娱乐→开心' 'happy' (Scenario 10 'play' 9999 $false 1.0 '') 'kind=play'
Check '鼠标靠近→观察' 'observe' (Scenario 10 'neutral' 120 $false 1.0 '') 'dist=120'
Check '无特别→idle' 'idle' (Scenario 10 'neutral' 9999 $false 1.0 '') 'nothing special'
Check '离开很久回来→alert' 'alert' (Scenario 1 'neutral' 9999 $false 1.0 'return' 900) 'away=900s'
Check '离开一会儿回来→happy' 'happy' (Scenario 1 'neutral' 9999 $false 1.0 'return' 30) 'away=30s'

Write-Host ''
Write-Host '--- 情绪映射 ---'
Check 'happy→开心' '开心' (Get-EmotionForState 'happy') ''
Check 'focused→专注' '专注' (Get-EmotionForState 'focused') ''
Check 'sleeping→安睡' '安睡' (Get-EmotionForState 'sleeping') ''
Check 'tired→困倦' '困倦' (Get-EmotionForState 'tired') ''

Write-Host ''
Write-Host '--- 应用分类 ---'
Check 'code.exe→work' 'work' (Get-AppKind 'Code' 'DeskPet.ps1 - Visual Studio Code') 'proc=Code'
Check 'chrome+标书→work' 'work' (Get-AppKind 'chrome' 'XX项目技术标 - 腾讯文档') '标题含标书'
Check 'chrome+bilibili→play' 'play' (Get-AppKind 'chrome' '哔哩哔哩 (゜-゜)つロ') '标题含bilibili'
Check 'winword→work' 'work' (Get-AppKind 'WINWORD' '技术方案.docx') 'proc=WINWORD'
Check 'steam→play' 'play' (Get-AppKind 'steam' 'Steam') 'proc=steam'
Check '未知→neutral' 'neutral' (Get-AppKind 'unknownapp' 'something') ''

Write-Host ''
Write-Host '--- 说话不重复 ---'
$pool = @(Get-PersonaLines 'speech' 'idle')
$Script:Memory['recentLines'] = @()
$said = @()
for ($i = 0; $i -lt 6; $i++) { $said += (Select-Line $pool) }
$uniq = @($said | Select-Object -Unique)
if ($uniq.Count -ge [Math]::Min(6, $pool.Count)) { Write-Host "PASS  连续 6 次不重复  (unique=$($uniq.Count)/$($pool.Count))" }
else { $script:fail++; Write-Host "FAIL  有重复  unique=$($uniq.Count)  $($said -join ' | ')" }

Write-Host ''
Write-Host '--- 输出结构 ---'
$snap = Get-BrainSnapshot
$keys = @($snap.Keys) -join ','
if ($keys -eq 'state,emotion,next_action,speech,reason') { Write-Host "PASS  字段齐全: $keys" }
else { $script:fail++; Write-Host "FAIL  字段: $keys" }
Write-Host ($snap | ConvertTo-Json)

Write-Host ''
Write-Host "TOTAL FAIL: $script:fail"
