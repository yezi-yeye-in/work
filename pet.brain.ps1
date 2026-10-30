# ══════════════════════════════════════════════════════════════════
#  pet.brain.ps1 —— 桌宠的"大脑"
#
#  职责：
#    1. 感知：鼠标 / 输入空闲时长 / 前台窗口程序 / 时间
#    2. 决策：状态机（idle/observe/happy/focused/tired/sleeping/alert/speaking/interacting）
#    3. 表达：动作选择 + 台词生成（人格一致、不重复、看场景）
#    4. 记忆：互动历史、亲密度、最近说过的话（持久化到 pet.memory.json）
#
#  被 DeskPet.ps1 用 . (dot-source) 载入，共用同一个作用域。
# ══════════════════════════════════════════════════════════════════

# ────────────── 原生感知 ──────────────
if (-not ('PetBrain.Native' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace PetBrain {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

        [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

        // 系统级"最后一次键鼠输入"距今秒数 —— 判断用户是否在操作电脑
        public static double IdleSeconds() {
            var li = new LASTINPUTINFO();
            li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref li)) return 0;
            uint now = (uint)Environment.TickCount;
            uint diff = now - li.dwTime;
            return diff / 1000.0;
        }

        // 返回 [进程名, 窗口标题, pid, 窗口类名]
        // 有些进程拿不到名字（受保护/跨会话），窗口类名可以兜底识别
        public static string[] Foreground() {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return new string[] { "", "", "0", "" };
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            var cn = new StringBuilder(256);
            GetClassName(h, cn, 256);
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            string proc = "";
            try {
                if (pid != 0) proc = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
            }
            catch { }
            return new string[] { proc, sb.ToString(), pid.ToString(), cn.ToString() };
        }
    }
}
'@
}

# ────────────── 应用分类词表 ──────────────
$Script:BrainWorkProcs = @(
    'code', 'code - insiders', 'devenv', 'idea64', 'pycharm64', 'webstorm', 'goland64', 'clion64',
    'sublime_text', 'notepad', 'notepad++', 'typora', 'obsidian',
    'winword', 'excel', 'powerpnt', 'wps', 'et', 'wpp',
    'acrobat', 'acrord32', 'sumatrapdf', 'foxitreader', 'foxitpdfreader', 'cajviewer',
    'windowsterminal', 'cmd', 'powershell', 'pwsh', 'conhost', 'mintty', 'git-bash',
    'mstsc', 'xmind', 'navicat', 'sqlyog', 'postman', 'dbeaver', 'redis-cli',
    'outlook', 'teams', 'onedrive', 'everything', 'sharex'
)
$Script:BrainPlayProcs = @(
    'steam', 'steamwebhelper', 'cloudmusic', 'qqmusic', 'spotify', 'foobar2000',
    'potplayermini64', 'vlc', 'bilibili', 'iqiyi', 'youku', 'qmdesktop'
)
$Script:BrainBrowserProcs = @(
    'chrome', 'msedge', 'firefox', 'opera', 'brave', '360se', '360chrome', 'sogouexplorer', 'qqbrowser'
)
$Script:BrainChatProcs = @( 'wechat', 'weixin', 'qq', 'dingtalk', 'wxwork', 'telegram', 'discord', 'feishu', 'lark' )

$Script:BrainWorkWords = @(
    '代码', 'visual studio', 'github', 'stack overflow', '文档', '表格', '演示', 'ppt', 'word', 'excel',
    'api', '数据库', '终端', 'terminal', '需求', '方案', '合同', '标书', '投标', '报价', '技术标', '商务标',
    '评分', '招标', '开标', '飞书文档', '腾讯文档', '石墨', '会议', '编程', '调试', '日报', '周报',
    'project', 'debug', 'readme', '编辑器', '工程'
)
$Script:BrainPlayWords = @(
    '哔哩哔哩', 'bilibili', '抖音', 'douyin', 'youtube', 'netflix', '微博', 'weibo', '小红书', '知乎',
    '游戏', 'steam', 'twitch', '爱奇艺', '优酷', '腾讯视频', '芒果', '动漫', '番剧', '直播',
    '贴吧', '虎牙', '斗鱼', '音乐', '网易云', '视频', '小说', '漫画', 'movie', 'anime', '播放'
)
$Script:BrainChatWords = @(
    '微信', 'wechat', 'weixin', 'qq', '钉钉', 'dingtalk', '飞书', 'feishu', 'lark', 'telegram',
    'discord', '企业微信', '聊天', '消息'
)

function Test-AnyWord([string]$text, $words) {
    if (-not $text) { return $false }
    foreach ($w in $words) {
        if ($text.Contains(([string]$w).ToLowerInvariant())) { return $true }
    }
    return $false
}

# 窗口类名兜底：拿不到进程名时，靠窗口类判断
function Get-ClassKind([string]$cls) {
    if (-not $cls) { return '' }
    $c = $cls.ToLowerInvariant()
    if ($c.Contains('chrome_widgetwin') -or $c.Contains('mozilla') -or $c.Contains('opera')) { return 'browser' }
    if ($c.Contains('wechatmainwnd') -or $c.Contains('weixin')) { return 'chat' }
    if ($c.Contains('opusapp')) { return 'work' }        # Word
    if ($c.Contains('xlmain')) { return 'work' }         # Excel
    if ($c.Contains('pp12frame') -or $c.Contains('pp14frame')) { return 'work' }   # PowerPoint
    if ($c.Contains('notepad')) { return 'work' }
    if ($c.Contains('consolewindowclass') -or $c.Contains('cascadia')) { return 'work' }   # 终端
    if ($c.Contains('scintilla')) { return 'work' }      # Notepad++
    return ''
}

# ────────────── 记忆 ──────────────
$Script:MemoryPath = Join-Path $Root 'pet.memory.json'
$Script:BrainLogPath = Join-Path $Root 'pet.brain.log'

function New-DefaultMemory {
    return [ordered]@{
        firstSeen     = (Get-Date -Format 's')
        lastSeen      = (Get-Date -Format 's')
        sessions      = 0
        clicks        = 0
        drags         = 0
        drops         = 0
        pets          = 0
        returns       = 0
        affinity      = 12.0
        recentLines   = @()
        lastState     = 'idle'
        lastEmotion   = '安静'
        workMinutes   = 0.0
        playMinutes   = 0.0
        streakDays    = 1
    }
}

function Import-BrainMemory {
    $mem = New-DefaultMemory
    if (Test-Path -LiteralPath $Script:MemoryPath) {
        try {
            $raw = Get-Content -LiteralPath $Script:MemoryPath -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            $def = New-DefaultMemory
            foreach ($k in $def.Keys) {
                if ($obj.PSObject.Properties[$k]) { $mem[$k] = $obj.$k }
            }
            # 连续使用天数
            try {
                $last = [DateTime]::Parse([string]$mem['lastSeen'])
                $gap = (Get-Date).Date - $last.Date
                if ($gap.TotalDays -ge 1 -and $gap.TotalDays -lt 2) { $mem['streakDays'] = [int]$mem['streakDays'] + 1 }
                elseif ($gap.TotalDays -ge 2) { $mem['streakDays'] = 1 }
            }
            catch { }
            $mem['sessions'] = [int]$mem['sessions'] + 1
        }
        catch { }
    }
    else {
        $mem['sessions'] = 1
    }
    $mem['lastSeen'] = (Get-Date -Format 's')
    return $mem
}

function Save-BrainMemory {
    try {
        $Script:Memory['lastSeen'] = (Get-Date -Format 's')
        $Script:Memory['lastState'] = [string]$Script:Br['state']
        $Script:Memory['lastEmotion'] = [string]$Script:Br['emotion']
        ($Script:Memory | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Script:MemoryPath -Encoding UTF8
    }
    catch { }
}

# ────────────── 大脑状态 ──────────────
$Script:Memory = Import-BrainMemory
$Script:Persona = $null
try {
    $Script:Persona = Get-Content -LiteralPath (Join-Path $Root 'pet.persona.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch { }

$Script:Br = [hashtable]::Synchronized(@{})
$Script:Br['state'] = 'idle'
$Script:Br['emotion'] = '安静'
$Script:Br['action'] = 'blink'
$Script:Br['actionUntil'] = [DateTime]::MinValue
$Script:Br['actionStartedAt'] = [DateTime]::Now
$Script:Br['speech'] = ''
$Script:Br['reason'] = '刚醒来，先观察一下'
$Script:Br['lastDecideAt'] = [DateTime]::MinValue
$Script:Br['lastSpeechAt'] = [DateTime]::MinValue
$Script:Br['lastFgAt'] = [DateTime]::MinValue
$Script:Br['fgProc'] = ''
$Script:Br['fgTitle'] = ''
$Script:Br['fgClass'] = ''
$Script:Br['fgKind'] = 'neutral'
$Script:Br['idleSeconds'] = 0.0
$Script:Br['prevIdleSeconds'] = 0.0
$Script:Br['wasAway'] = $false
$Script:Br['awaySeconds'] = 0.0
$Script:Br['lastActiveAt'] = [DateTime]::Now
$Script:Br['pendingEvent'] = ''
$Script:Br['eventAt'] = [DateTime]::MinValue
$Script:Br['mood'] = 0.0            # -1 低落 .. +1 愉快
$Script:Br['energy'] = 1.0         # 0 精疲力尽 .. 1 精神饱满
$Script:Br['stateSince'] = [DateTime]::Now
$Script:Br['lastActionAt'] = [DateTime]::MinValue
$Script:Br['quiet'] = $false
$Script:Br['lastEvent'] = ''
$Script:Br['lastLogSig'] = ''
$Script:Br['lastSaveAt'] = [DateTime]::Now

# ────────────── 感知 ──────────────
function Update-BrainSenses {
    param([double]$dt)

    # 1) 输入空闲时长（每帧都便宜，直接取）
    try { $Script:Br['idleSeconds'] = [double][PetBrain.Native]::IdleSeconds() } catch { }

    # 2) 前台窗口（1.5 秒查一次就够）
    $now = [DateTime]::Now
    if (($now - [DateTime]$Script:Br['lastFgAt']).TotalSeconds -ge 1.5) {
        $Script:Br['lastFgAt'] = $now
        try {
            $fg = [PetBrain.Native]::Foreground()
            $proc = [string]$fg[0]
            $title = [string]$fg[1]
            $cls = ''
            if ($fg.Length -ge 4) { $cls = [string]$fg[3] }
            $Script:Br['fgProc'] = $proc
            $Script:Br['fgTitle'] = $title
            $Script:Br['fgClass'] = $cls
            $Script:Br['fgKind'] = Get-AppKind $proc $title $cls
        }
        catch { }
    }

    # 3) 用户是否"刚离开又回来"
    $idle = [double]$Script:Br['idleSeconds']
    $prev = [double]$Script:Br['prevIdleSeconds']
    if ($idle -lt 2.0) {
        if ([bool]$Script:Br['wasAway']) {
            $Script:Br['wasAway'] = $false
            $Script:Br['pendingEvent'] = 'return'
            $Script:Br['eventAt'] = $now
            $Script:Memory['returns'] = [int]$Script:Memory['returns'] + 1
            $Script:Memory['affinity'] = [Math]::Min(100.0, [double]$Script:Memory['affinity'] + 2.0)
            $Script:Br['mood'] = [Math]::Min(1.0, [double]$Script:Br['mood'] + 0.25)
        }
        $Script:Br['lastActiveAt'] = $now
    }
    else {
        if (-not [bool]$Script:Br['wasAway'] -and $idle -gt 45) {
            $Script:Br['wasAway'] = $true
            $Script:Br['awaySeconds'] = 0.0
        }
        if ([bool]$Script:Br['wasAway']) {
            $Script:Br['awaySeconds'] = [double]$Script:Br['awaySeconds'] + $dt
        }
    }
    $Script:Br['prevIdleSeconds'] = $idle

    # 4) 精力：久坐工作会掉，休息会回
    $drain = 0.0
    if ([string]$Script:Br['fgKind'] -eq 'work' -and $idle -lt 60) { $drain = 0.010 }
    elseif ($idle -gt 120) { $drain = -0.020 }
    else { $drain = 0.002 }
    $Script:Br['energy'] = [Math]::Max(0.0, [Math]::Min(1.0, [double]$Script:Br['energy'] - $drain * $dt))

    # 5) 情绪缓慢回归中性
    $Script:Br['mood'] = [double]$Script:Br['mood'] * (1.0 - 0.02 * $dt)

    # 6) 累计工作/摸鱼时长
    if ($idle -lt 60) {
        if ([string]$Script:Br['fgKind'] -eq 'work') { $Script:Memory['workMinutes'] = [double]$Script:Memory['workMinutes'] + $dt / 60.0 }
        elseif ([string]$Script:Br['fgKind'] -eq 'play') { $Script:Memory['playMinutes'] = [double]$Script:Memory['playMinutes'] + $dt / 60.0 }
    }
}

function Get-AppKind([string]$proc, [string]$title, [string]$cls = '') {
    $p = ''
    if ($proc) { $p = $proc.ToLowerInvariant() }
    $tt = ''
    if ($title) { $tt = $title.ToLowerInvariant() }
    $ck = ''
    if ($cls) { $ck = Get-ClassKind $cls }

    # 1) 进程名能认出来时，优先按进程判断（最准）
    if ($p) {
        if ($Script:BrainPlayProcs -contains $p) { return 'play' }
        if ($Script:BrainWorkProcs -contains $p) { return 'work' }
        if ($Script:BrainChatProcs -contains $p) { return 'chat' }
    }

    # 2) 进程名拿不到时，用窗口类名兜底
    if ($ck -eq 'chat') { return 'chat' }
    if ($ck -eq 'work' -and -not $p) { return 'work' }

    # 3) 按窗口标题判断（中文标题信息量很大）
    if (Test-AnyWord $tt $Script:BrainChatWords) { return 'chat' }
    if (Test-AnyWord $tt $Script:BrainPlayWords) { return 'play' }
    if (Test-AnyWord $tt $Script:BrainWorkWords) { return 'work' }

    # 4) 浏览器没匹配到关键词 —— 只能算"随便看看"
    $isBrowser = ($p -and ($Script:BrainBrowserProcs -contains $p)) -or ($ck -eq 'browser')
    if ($isBrowser) { return 'browse' }

    return 'neutral'
}

function Get-TimeSlot {
    $h = (Get-Date).Hour
    if ($h -ge 5 -and $h -lt 11) { return 'morning' }
    if ($h -ge 11 -and $h -lt 14) { return 'noon' }
    if ($h -ge 14 -and $h -lt 18) { return 'afternoon' }
    if ($h -ge 18 -and $h -lt 23) { return 'evening' }
    return 'lateNight'
}

# ────────────── 说话 ──────────────
function Get-PersonaLines([string]$group, [string]$key) {
    if (-not $Script:Persona) { return @() }
    try {
        $g = $Script:Persona.$group
        if (-not $g) { return @() }
        $arr = $g.$key
        if (-not $arr) { return @() }
        return @($arr)
    }
    catch { return @() }
}

function Select-Line([string[]]$pool) {
    if (-not $pool -or $pool.Count -eq 0) { return '' }
    $recent = @($Script:Memory['recentLines'])
    $cands = @($pool | Where-Object { $recent -notcontains $_ })
    if ($cands.Count -eq 0) { $cands = @($pool) }
    $pick = [string]($cands | Get-Random)
    # 记入"最近说过"，最多留 14 条，避免机械重复
    $newRecent = @($pick) + $recent
    if ($newRecent.Count -gt 14) { $newRecent = $newRecent[0..13] }
    $Script:Memory['recentLines'] = $newRecent
    return $pick
}

function Get-SpeechMinInterval([string]$state) {
    switch ($state) {
        'alert' { return 0 }
        'interacting' { return 22 }
        'happy' { return 26 }
        'tired' { return 42 }
        'observe' { return 58 }
        'idle' { return 48 }
        'focused' { return 210 }
        'sleeping' { return 150 }
        default { return 60 }
    }
}

function New-BrainSpeech([string]$state, [bool]$force) {
    $now = [DateTime]::Now
    $minGap = Get-SpeechMinInterval $state
    if (-not $force -and ($now - [DateTime]$Script:Br['lastSpeechAt']).TotalSeconds -lt $minGap) { return '' }

    $slot = Get-TimeSlot
    $pool = @()

    # 深夜优先说"该睡了"
    if ($slot -eq 'lateNight' -and (Get-Random -Maximum 100) -lt 40) {
        $pool = @(Get-PersonaLines 'events' 'night')
    }
    if ($pool.Count -eq 0) { $pool = @(Get-PersonaLines 'speech' $state) }
    if ($pool.Count -eq 0) { $pool = @(Get-PersonaLines 'speech' 'idle') }
    # 少量时间语，增加"活着"的感觉（只在闲聊/观察时插，不打断状态化的表达）
    if ($pool.Count -gt 0 -and ($state -eq 'idle' -or $state -eq 'observe') -and (Get-Random -Maximum 100) -lt 15) {
        $t = @(Get-PersonaLines 'timeLines' $slot)
        if ($t.Count -gt 0) { $pool = $t }
    }

    $line = Select-Line $pool
    if ($line) {
        $Script:Br['lastSpeechAt'] = $now
        $Script:Br['speech'] = $line
    }
    return $line
}

# ────────────── 动作 ──────────────
function Set-BrainAction([string]$action, [int]$ms) {
    $Script:Br['action'] = $action
    $Script:Br['actionStartedAt'] = [DateTime]::Now
    $Script:Br['actionUntil'] = [DateTime]::Now.AddMilliseconds([Math]::Max(120, $ms))
    $Script:Br['lastActionAt'] = [DateTime]::Now
}

function Get-ActionForState([string]$state) {
    switch ($state) {
        'sleeping' { return @{ a = 'daze'; ms = 6000 } }
        'tired' { return @{ a = 'yawn'; ms = 1600 } }
        'focused' { return @{ a = 'look_at_screen'; ms = 2400 } }
        'happy' { return @{ a = 'wave'; ms = 1100 } }
        'alert' { return @{ a = 'wave'; ms = 1200 } }
        'observe' { return @{ a = 'look_at_mouse'; ms = 1800 } }
        'interacting' { return @{ a = 'look_at_mouse'; ms = 800 } }
        default {
            $r = Get-Random -Maximum 100
            if ($r -lt 34) { return @{ a = 'blink'; ms = 240 } }
            elseif ($r -lt 56) { return @{ a = 'nod'; ms = 700 } }
            elseif ($r -lt 74) { return @{ a = 'daze'; ms = 2600 } }
            elseif ($r -lt 88) { return @{ a = 'look_at_mouse'; ms = 1500 } }
            else { return @{ a = 'follow_desktop'; ms = 9000 } }
        }
    }
}

# ────────────── 状态机 ──────────────
function Get-DesiredState {
    $idle = [double]$Script:Br['idleSeconds']
    $kind = [string]$Script:Br['fgKind']
    $energy = [double]$Script:Br['energy']
    $hour = (Get-Date).Hour

    # 1) 正在被拖动 / 按下 —— 最高优先级
    if ([bool]$St['dragging'] -or [bool]$St['pressed']) { return @('interacting', '被你抓着，只能配合') }

    # 2) 刚回来
    if ([string]$Script:Br['pendingEvent'] -eq 'return') {
        $away = [double]$Script:Br['awaySeconds']
        if ($away -gt 600) { return @('alert', "你离开了 $([int]($away/60)) 分钟，刚回来") }
        if ($away -gt 90) { return @('alert', "你离开了一会儿，刚回来") }
        return @('happy', '你刚回到电脑前')
    }

    # 2.5) 刚被戳 / 被摸 / 刚放下 —— 先开心一下，别被"鼠标靠近"盖掉
    $ev = [string]$Script:Br['pendingEvent']
    if ($ev -eq 'click' -or $ev -eq 'pet' -or $ev -eq 'drop') {
        return @('happy', '你刚碰了我一下')
    }

    # 3) 气泡正在说话
    if ($Bubble.Visible) {
        $said = [string]$Script:Br['speech']
        if ($said) { return @('speaking', "正在对你说：$said") }
        return @('speaking', '正在说话')
    }

    # 4) 睡着：长时间无输入
    if ($idle -gt 300) { return @('sleeping', "你已经 $([int]($idle/60)) 分钟没动了") }

    # 5) 困了：中等时长无输入，或精力低，或深夜
    if ($idle -gt 90) { return @('tired', "你 $([int]$idle) 秒没动了") }
    if ($energy -lt 0.25) { return @('tired', '陪你太久，精力见底了') }
    if (($hour -ge 1 -and $hour -lt 5) -and $energy -lt 0.55) { return @('tired', '深夜了，本骑士也困') }

    # 6) 专注：用户在工作
    if ($kind -eq 'work' -and $idle -lt 45) {
        $who = [string]$Script:Br['fgProc']
        if (-not $who) { $who = '前台窗口' }
        return @('focused', "你在忙正事（$who）")
    }

    # 7) 开心：用户在娱乐
    if ($kind -eq 'play' -and $idle -lt 45) {
        return @('happy', "你在摸鱼，我也想凑热闹")
    }

    # 8) 观察：鼠标靠近宠物
    $dist = [double]$St['dist']
    if ($dist -lt 260) { return @('observe', '鼠标靠近了，我在看你') }

    # 9) 闲聊场景
    if ($kind -eq 'chat') { return @('observe', '你在聊天，我安静看着') }

    return @('idle', '没什么特别的事')
}

function Get-EmotionForState([string]$state) {
    $mood = [double]$Script:Br['mood']
    switch ($state) {
        'alert' { if ($mood -gt 0.3) { return '惊喜' } else { return '警觉' } }
        'happy' { return '开心' }
        'focused' { return '专注' }
        'tired' { return '困倦' }
        'sleeping' { return '安睡' }
        'interacting' { return '慌' }
        'observe' { return '好奇' }
        'speaking' { return '温柔' }
        default {
            if ($mood -gt 0.45) { return '满足' }
            if ($mood -lt -0.3) { return '低落' }
            if ((Get-TimeSlot) -eq 'lateNight') { return '安静' }
            return '平静'
        }
    }
}

# ────────────── 主决策 ──────────────
function Invoke-BrainTick {
    param([double]$dt)

    Update-BrainSenses $dt

    $now = [DateTime]::Now
    # 每 1.1 秒做一次决策，避免每帧都算
    if (($now - [DateTime]$Script:Br['lastDecideAt']).TotalSeconds -lt 1.1) { return }
    $Script:Br['lastDecideAt'] = $now

    $decision = Get-DesiredState
    $state = [string]$decision[0]
    $reason = [string]$decision[1]
    $prevState = [string]$Script:Br['state']

    if ($state -ne $prevState) {
        $Script:Br['stateSince'] = $now
        $Script:Br['mood'] = [Math]::Max(-1.0, [Math]::Min(1.0, [double]$Script:Br['mood']))
    }
    $Script:Br['state'] = $state
    $Script:Br['emotion'] = Get-EmotionForState $state
    $Script:Br['reason'] = $reason

    # ── 动作：状态刚变化时立刻给一个，之后按节奏换
    $actionExpired = $now -ge [DateTime]$Script:Br['actionUntil']
    if ($state -ne $prevState -or $actionExpired) {
        $act = Get-ActionForState $state
        Set-BrainAction ([string]$act['a']) ([int]$act['ms'])
    }

    # ── 说话：事件优先，其次按状态节奏
    $speak = ''

    if ([string]$Script:Br['pendingEvent'] -eq 'return') {
        $away = [double]$Script:Br['awaySeconds']
        if ($away -gt 600) { $speak = Select-Line @(Get-PersonaLines 'events' 'returnLong') }
        elseif ($away -gt 90) { $speak = Select-Line @(Get-PersonaLines 'events' 'returnShort') }
        $Script:Br['pendingEvent'] = ''
    }
    elseif ([string]$Script:Br['pendingEvent'] -eq 'click') {
        $speak = Select-Line @(Get-PersonaLines 'events' 'click')
        $Script:Br['pendingEvent'] = ''
    }
    elseif ([string]$Script:Br['pendingEvent'] -eq 'drag') {
        $speak = Select-Line @(Get-PersonaLines 'events' 'drag')
        $Script:Br['pendingEvent'] = ''
    }
    elseif ([string]$Script:Br['pendingEvent'] -eq 'drop') {
        $speak = Select-Line @(Get-PersonaLines 'events' 'drop')
        $Script:Br['pendingEvent'] = ''
    }
    elseif ([string]$Script:Br['pendingEvent'] -eq 'workStart') {
        $speak = Select-Line @(Get-PersonaLines 'events' 'workStart')
        $Script:Br['pendingEvent'] = ''
    }
    elseif ([string]$Script:Br['pendingEvent'] -eq 'playStart') {
        $speak = Select-Line @(Get-PersonaLines 'events' 'playStart')
        $Script:Br['pendingEvent'] = ''
    }
    elseif ($state -eq 'sleeping') {
        if ((Get-Random -Maximum 100) -lt 18) { $speak = New-BrainSpeech 'sleeping' $false }
    }
    elseif ($state -eq 'speaking') {
        # 已经在说话了，别自己接自己的话
        $speak = ''
    }
    else {
        $speak = New-BrainSpeech $state $false
    }

    if ($speak) {
        # "话少一点"模式下，只有事件类（回来/被戳）才出声
        $eventSpeech = @('alert', 'interacting')
        if ([bool]$Script:Br['quiet'] -and ($eventSpeech -notcontains $state) -and [string]$Script:Br['pendingEvent'] -eq '') {
            $speak = ''
        }
    }

    if ($speak) {
        $Script:Br['speech'] = $speak
        $Script:Br['lastSpeechAt'] = $now
        Show-Speech $speak
    }

    # ── 把决策写入日志（JSON Lines，方便观察它在想什么）
    Write-BrainLog

    # ── 每 60 秒自动存一次记忆，避免被强制关闭时丢数据
    if (($now - [DateTime]$Script:Br['lastSaveAt']).TotalSeconds -ge 60) {
        $Script:Br['lastSaveAt'] = $now
        Save-BrainMemory
    }
}

function Write-BrainLog {
    try {
        $snap = Get-BrainSnapshot
        # 只在状态/情绪/动作/台词真的变了时记录，避免日志被重复行淹没
        $sig = "$($snap['state'])|$($snap['emotion'])|$($snap['next_action'])|$($snap['speech'])"
        if ($sig -eq [string]$Script:Br['lastLogSig']) { return }
        $Script:Br['lastLogSig'] = $sig

        if ((Test-Path -LiteralPath $Script:BrainLogPath) -and ((Get-Item $Script:BrainLogPath).Length -gt 400KB)) {
            Remove-Item -LiteralPath $Script:BrainLogPath -Force -ErrorAction SilentlyContinue
        }
        $json = $snap | ConvertTo-Json -Compress -Depth 4
        [System.IO.File]::AppendAllText($Script:BrainLogPath, "$([DateTime]::Now.ToString('MM-dd HH:mm:ss')) $json`r`n")
    }
    catch { }
}

# ────────────── 对外输出（严格按要求的结构） ──────────────
function Get-BrainSnapshot {
    return [ordered]@{
        state       = [string]$Script:Br['state']
        emotion     = [string]$Script:Br['emotion']
        next_action = [string]$Script:Br['action']
        speech      = [string]$Script:Br['speech']
        reason      = [string]$Script:Br['reason']
    }
}

function Get-BrainDebugText {
    $s = Get-BrainSnapshot
    $idle = [Math]::Round([double]$Script:Br['idleSeconds'], 1)
    $kind = [string]$Script:Br['fgKind']
    $proc = [string]$Script:Br['fgProc']
    $title = [string]$Script:Br['fgTitle']
    $cls = [string]$Script:Br['fgClass']
    if ($title.Length -gt 30) { $title = $title.Substring(0, 30) + '…' }
    if (-not $proc) { $proc = "（未知，类名 $cls）" }
    $lines = @(
        "状态：$($s['state'])   情绪：$($s['emotion'])",
        "动作：$($s['next_action'])",
        "原因：$($s['reason'])",
        "—— 环境 ——",
        "空闲：${idle}s",
        "前台：$proc [$kind]",
        "标题：$title",
        "精力：$([Math]::Round([double]$Script:Br['energy']*100))%  心情：$([Math]::Round([double]$Script:Br['mood']*100))%",
        "亲密：$([Math]::Round([double]$Script:Memory['affinity']))  连续：$($Script:Memory['streakDays']) 天",
        "点过：$($Script:Memory['clicks'])  拖过：$($Script:Memory['drags'])  离开后回来：$($Script:Memory['returns']) 次"
    )
    return ($lines -join "`r`n")
}

# ────────────── 事件接口（由 DeskPet.ps1 调用） ──────────────
function Send-BrainEvent([string]$name) {
    $Script:Br['pendingEvent'] = $name
    $Script:Br['eventAt'] = [DateTime]::Now
    switch ($name) {
        'click' { $Script:Memory['clicks'] = [int]$Script:Memory['clicks'] + 1; $Script:Br['mood'] = [Math]::Min(1.0, [double]$Script:Br['mood'] + 0.18); $Script:Memory['affinity'] = [Math]::Min(100.0, [double]$Script:Memory['affinity'] + 1.0) }
        'drag' { $Script:Memory['drags'] = [int]$Script:Memory['drags'] + 1; $Script:Br['mood'] = [Math]::Max(-1.0, [double]$Script:Br['mood'] - 0.05) }
        'drop' { $Script:Memory['drops'] = [int]$Script:Memory['drops'] + 1; $Script:Br['mood'] = [Math]::Min(1.0, [double]$Script:Br['mood'] + 0.10); $Script:Memory['affinity'] = [Math]::Min(100.0, [double]$Script:Memory['affinity'] + 1.0) }
        'pet' { $Script:Memory['pets'] = [int]$Script:Memory['pets'] + 1; $Script:Br['mood'] = [Math]::Min(1.0, [double]$Script:Br['mood'] + 0.30); $Script:Memory['affinity'] = [Math]::Min(100.0, [double]$Script:Memory['affinity'] + 1.5) }
    }
    # 事件立刻触发一次决策，不用等下一个 1.1 秒
    $Script:Br['lastDecideAt'] = [DateTime]::MinValue
}
