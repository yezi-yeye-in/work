# demo-states.ps1 —— 演示不同场景下角色会怎么判断、说什么
# 用法： powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\demo-states.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Root = $root

$St = @{ dragging = $false; pressed = $false; dist = 9999.0; petX = 1000.0; petY = 600.0 }
$Bubble = [pscustomobject]@{ Visible = $false }
function Show-Speech([string]$t) { }
. (Join-Path $root 'pet.brain.ps1')

# 场景定义：名称 / 空闲秒 / 前台类型 / 鼠标距离 / 拖动 / 精力 / 事件 / 离开时长
$cases = @(
    @{ n = '用户正在写标书';        idle = 8;   kind = 'work';    dist = 9999; drag = $false; energy = 0.8; ev = '';       away = 0 }
    @{ n = '用户在看视频';          idle = 6;   kind = 'play';    dist = 9999; drag = $false; energy = 0.9; ev = '';       away = 0 }
    @{ n = '鼠标凑到跟前';          idle = 5;   kind = 'neutral'; dist = 90;   drag = $false; energy = 0.9; ev = '';       away = 0 }
    @{ n = '离开 3 分钟后回来';      idle = 1;   kind = 'neutral'; dist = 9999; drag = $false; energy = 0.9; ev = 'return'; away = 180 }
    @{ n = '离开 40 分钟后回来';     idle = 1;   kind = 'neutral'; dist = 9999; drag = $false; energy = 0.9; ev = 'return'; away = 2400 }
    @{ n = '两分钟没动，犯困';       idle = 120; kind = 'neutral'; dist = 9999; drag = $false; energy = 0.6; ev = '';       away = 0 }
    @{ n = '六分钟没动，睡着';       idle = 360; kind = 'neutral'; dist = 9999; drag = $false; energy = 0.5; ev = '';       away = 0 }
    @{ n = '被鼠标拎起来';          idle = 0;   kind = 'neutral'; dist = 50;   drag = $true;  energy = 0.9; ev = '';       away = 0 }
    @{ n = '被戳了一下';            idle = 0;   kind = 'neutral'; dist = 50;   drag = $false; energy = 0.9; ev = 'click';  away = 0 }
)

$out = @()
foreach ($c in $cases) {
    $Script:Br['idleSeconds'] = [double]$c.idle
    $Script:Br['fgKind'] = [string]$c.kind
    $Script:Br['energy'] = [double]$c.energy
    $Script:Br['pendingEvent'] = [string]$c.ev
    $Script:Br['awaySeconds'] = [double]$c.away
    $St['dragging'] = [bool]$c.drag
    $St['pressed'] = $false
    $St['dist'] = [double]$c.dist
    $Bubble.Visible = $false
    $Script:Br['lastSpeechAt'] = [DateTime]::MinValue

    $d = Get-DesiredState
    $state = [string]$d[0]
    $Script:Br['state'] = $state
    $Script:Br['emotion'] = Get-EmotionForState $state
    $Script:Br['reason'] = [string]$d[1]
    $act = Get-ActionForState $state
    $Script:Br['action'] = [string]$act['a']

    # 事件类台词优先，否则按状态生成
    $speech = ''
    if ([string]$c.ev -eq 'return') {
        if ($c.away -gt 600) { $speech = Select-Line @(Get-PersonaLines 'events' 'returnLong') }
        else { $speech = Select-Line @(Get-PersonaLines 'events' 'returnShort') }
    }
    elseif ([string]$c.ev -eq 'click') { $speech = Select-Line @(Get-PersonaLines 'events' 'click') }
    else { $speech = New-BrainSpeech $state $true }
    $Script:Br['speech'] = $speech

    $snap = Get-BrainSnapshot
    $out += [pscustomobject]@{
        场景 = $c.n
        JSON = ($snap | ConvertTo-Json -Compress)
    }
}

foreach ($o in $out) {
    Write-Host ''
    Write-Host "【$($o.场景)】"
    $o.JSON -replace '","', '" , "'
}
Write-Host ''
