<#
.SYNOPSIS
  hooks-ledger.ps1 —— 持续性钩子台账：登记 / 列表 / 预演 / 拆除 / 验证 / 通用扫描
.DESCRIPTION
  配合 legacy-refactor-flow skill 使用。核心约定：任何持续性钩子（MCP 注册、git hook、
  CI 门、常驻索引、daemon、环境变量、追加进 AGENTS.md 的段落等）在创建的同一刻登记，
  任务收尾时用 -Teardown -Apply 拆除，再用 -Verify 验证，全部清干净才算结束。
.EXAMPLE
  ./hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Register -Kind config -Path C:\repo\.mcp.json -Action modified -Backup _refactor-kit/backup/.mcp.json
  ./hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -List
  ./hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Teardown
  ./hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Teardown -Apply
  ./hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Verify
  ./hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Sweep -Repo C:\repo
  # -Sweep -Strict：连 [?]（可能是用户本来就有的东西）也判失败，逼你逐项确认
  # 扫描末尾会打一行 ASCII 计数 HARD=/CHECK=/UNCOVERED=，给上层程序读；
  # UNCOVERED 那几类（daemon/crontab/用户级环境变量/端口/跨仓）本工具判不了，必须另核
  #
  # 租约：登记时给 -TTLHours，条目就带 owner/expires；发起方半路死了也有人来收
  ./hooks-ledger.ps1 -Ledger ... -Register -Path C:\repo\.mcp.json -Action modified -Backup b.json -Owner sess-42 -TTLHours 6
  ./hooks-ledger.ps1 -Ledger ... -Renew -Owner sess-42 -TTLHours 6        # 干完之前续命
  ./hooks-ledger.ps1 -Ledger ... -Collect                                 # 干跑：列出过期未拆的孤儿
  ./hooks-ledger.ps1 -Ledger ... -Collect -Apply                          # 真拆；缺备份的一律不动
#>
param(
    [Parameter(Mandatory = $true)][string]$Ledger,
    [switch]$Register,
    [ValidateSet('file','dir','config','process','env','other')][string]$Kind = 'file',
    [string]$Path,
    [ValidateSet('created','modified','appended')][string]$Action = 'created',
    [string]$Backup,
    [string]$Note = "",
    # 租约：登记时给一个存活小时数，条目就带上到期时间；0 = 不过期（与旧版行为一致）
    [string]$Owner = "",
    [double]$TTLHours = 0,
    [switch]$List,
    [switch]$Teardown,
    [switch]$Apply,
    [switch]$Verify,
    [switch]$Sweep,
    [switch]$Strict,
    # 收集器：把租约已过期、但发起方没回来拆的条目当孤儿处理（默认只报不删）
    [switch]$Collect,
    [switch]$Renew,
    [string]$Repo
)

$ErrorActionPreference = "Stop"

# 中文输出按 UTF-8 编码：PS 5.1 默认按控制台 OEM 代码页输出，经管道/重定向给上层读时整片乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function Load-Ledger {
    param([string]$p)
    if (Test-Path -LiteralPath $p) {
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        if ($raw -and $raw.Trim() -ne "") {
            $o = $raw | ConvertFrom-Json
            if (-not $o.hooks) { $o | Add-Member -NotePropertyName hooks -NotePropertyValue @() -Force }
            return $o
        }
    }
    return [pscustomobject]@{ version = 1; created = (Get-Date -Format 's'); hooks = @() }
}

function Save-Ledger {
    param($obj, [string]$p)
    $dir = Split-Path -Parent $p
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $p -Encoding UTF8
}

function Get-Hash {
    param([string]$p)
    if (-not $p) { return $null }
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    if ((Get-Item -LiteralPath $p).PSIsContainer) { return "DIR" }
    return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
}

# 租约判定：没有 expires 字段（或为空）的条目**永不算过期** —— 收集器绝不碰它，
# 因为"没登记到期时间"不等于"已到期"，误删比漏删严重。
function Test-Expired {
    param($h)
    if (-not $h.expires) { return $false }
    try {
        $e = [DateTime]::Parse([string]$h.expires, [System.Globalization.CultureInfo]::InvariantCulture)
        return ($e -lt (Get-Date))
    } catch { return $false }
}

# 拆除单条：Teardown 与 Collect 共用同一具身体，避免两套逻辑走偏
function Invoke-RemoveOne {
    param($h, [bool]$apply)
    if ($h.action -eq 'created') {
        if (Test-Path -LiteralPath $h.path) {
            Write-Host ("  [删除] " + $h.path)
            if ($apply) { Remove-Item -LiteralPath $h.path -Recurse -Force; $h.removed = $true }
        } else {
            Write-Host ("  [跳过] 已不存在：" + $h.path)
            if ($apply) { $h.removed = $true }
        }
    } else {
        if (-not $h.backup -or -not (Test-Path -LiteralPath $h.backup)) {
            Write-Warning ("  [无法恢复] 缺备份：" + $h.path)
            return 'blocked'
        } else {
            Write-Host ("  [恢复] " + $h.path + "  <=  " + $h.backup)
            if ($apply) { Copy-Item -LiteralPath $h.backup -Destination $h.path -Force; $h.removed = $true }
        }
    }
    return 'done'
}

# ---------- 登记 ----------
if ($Register) {
    if (-not $Path) { throw "登记需要 -Path" }
    if ($Action -ne 'created' -and -not $Backup) { throw "-Action $Action 必须同时给 -Backup，否则无法恢复" }
    $full = [System.IO.Path]::GetFullPath($Path)
    $b = ""
    if ($Backup) { $b = [System.IO.Path]::GetFullPath($Backup) }
    if (-not $Owner) { $Owner = "$env:USERNAME" }
    $exp = ""
    if ($TTLHours -gt 0) { $exp = (Get-Date).AddHours($TTLHours).ToString('s') }
    $l = Load-Ledger $Ledger
    $entry = [pscustomobject]@{
        ts           = (Get-Date -Format 's')
        kind         = $Kind
        path         = $full
        action       = $Action
        backup       = $b
        originalHash = (Get-Hash $b)
        note         = $Note
        owner        = $Owner
        expires      = $exp
        removed      = $false
    }
    $l.hooks = @($l.hooks) + $entry
    Save-Ledger $l $Ledger
    Write-Host "[ledger] 已登记：$Action / $Kind / $full"
    if ($b) { Write-Host "[ledger] 备份：$b" }
    if ($exp) { Write-Host "[ledger] 租约：owner=$Owner 到期=$exp（过期后由 -Collect 接管，不必等发起方回来）" }
    else { Write-Host "[ledger] 租约：owner=$Owner 未设 TTL —— 收集器不会碰这条，拆除责任在发起方" }
    exit 0
}

# ---------- 续租 ----------
if ($Renew) {
    $l = Load-Ledger $Ledger
    $n = 0
    foreach ($h in @($l.hooks)) {
        if ($h.removed) { continue }
        if ($Path -and ([System.IO.Path]::GetFullPath($Path) -ne $h.path)) { continue }
        if (-not $Path -and $Owner -and $h.owner -ne $Owner) { continue }
        if (-not $h.expires) { continue }
        $h.expires = (Get-Date).AddHours($TTLHours).ToString('s'); $n++
        Write-Host ("  [续租] " + $h.path + " -> " + $h.expires)
    }
    if ($n -eq 0) { Write-Host "[renew] 没有可续的条目（只续带租约且未拆的；TTLHours 需 > 0）" }
    else { Save-Ledger $l $Ledger; Write-Host "[renew] RENEWED=$n" }
    exit 0
}

# ---------- 列表 ----------
if ($List) {
    $l = Load-Ledger $Ledger
    if (@($l.hooks).Count -eq 0) { Write-Host "[ledger] 台账为空。"; exit 0 }
    Write-Host "[ledger] 共 $(@($l.hooks).Count) 条："
    foreach ($h in $l.hooks) {
        $state = "待拆"
        if ($h.removed) { $state = "已拆" }
        elseif (Test-Expired $h) { $state = "过期" }
        $lease = if ($h.expires) { " 到期 " + $h.expires + " owner " + $h.owner } else { " 无租约" }
        Write-Host ("  [{0}] {1,-8} {2,-10} {3}{4}" -f $state, $h.action, $h.kind, $h.path, $lease)
    }
    exit 0
}

# ---------- 预演 / 拆除 ----------
if ($Teardown) {
    $l = Load-Ledger $Ledger
    $pending = @($l.hooks | Where-Object { -not $_.removed })
    if ($pending.Count -eq 0) { Write-Host "[teardown] 台账为空或已全部拆除。"; exit 0 }
    if ($Apply) { Write-Host "[teardown] 执行拆除，共 $($pending.Count) 项" } else { Write-Host "[teardown] 预演模式（不改动任何东西），共 $($pending.Count) 项。加 -Apply 执行。" }
    $blocked = 0
    # 注意：[bool]$Apply 必须先在**表达式模式**下算好再传；写成 Invoke-RemoveOne $h [bool]$Apply
    # 时参数模式不当它是转型，会把字符串塞给 [bool] 形参而绑参失败（实测踩过）。
    $doApply = [bool]$Apply
    foreach ($h in $pending) { if ((Invoke-RemoveOne -h $h -apply $doApply) -eq 'blocked') { $blocked++ } }
    if ($Apply) { Save-Ledger $l $Ledger; Write-Host "[teardown] 执行完毕。请运行 -Verify 验证。" }
    Write-Host ("[teardown] PENDING=" + $pending.Count + " BLOCKED=" + $blocked + " APPLIED=" + [int][bool]$Apply)
    if ($blocked -gt 0) { Write-Host "[teardown] $blocked 项缺备份、无法恢复 —— 判失败（别当拆过了）。"; exit 1 }
    exit 0
}

# ---------- 孤儿收集器（不依赖发起方活着） ----------
if ($Collect) {
    $l = Load-Ledger $Ledger
    $orphans = @($l.hooks | Where-Object { -not $_.removed -and (Test-Expired $_) })
    if ($Owner -and $orphans.Count -gt 0) { $orphans = @($orphans | Where-Object { $_.owner -eq $Owner }) }
    Write-Host ("[collect] 台账 " + @($l.hooks).Count + " 条，租约过期且未拆 " + $orphans.Count + " 条")
    if ($orphans.Count -eq 0) {
        Write-Host "[collect] ORPHAN=0 REMOVED=0"
        Write-Host "[collect] 无孤儿。（无租约条目一律不算孤儿 —— 那是发起方的责任，收集器不猜）"
        exit 0
    }
    if ($Apply) { Write-Host "[collect] 执行拆除，共 $($orphans.Count) 项" }
    else { Write-Host "[collect] 干跑模式（不改动任何东西）。确认无误再加 -Apply。" }
    $gone = 0; $blocked = 0
    $doApply = [bool]$Apply
    foreach ($h in $orphans) {
        Write-Host ("  [孤儿] " + $h.path + "  owner=" + $h.owner + " 到期=" + $h.expires)
        if ((Invoke-RemoveOne -h $h -apply $doApply) -eq 'blocked') { $blocked++ } else { $gone++ }
    }
    if ($Apply) { Save-Ledger $l $Ledger }
    Write-Host ("[collect] ORPHAN=" + $orphans.Count + " HANDLED=$gone BLOCKED=" + $blocked + " APPLIED=" + [int][bool]$Apply)
    if ($blocked -gt 0) { Write-Host "[collect] $blocked 项缺备份，收集器不动它（宁可留残留也不误删）。"; exit 1 }
    exit 0
}

# ---------- 验证 ----------
if ($Verify) {
    $l = Load-Ledger $Ledger
    $bad = 0
    $tot = @($l.hooks).Count
    $expired = @(@($l.hooks) | Where-Object { -not $_.removed -and (Test-Expired $_) }).Count
    Write-Host "[verify] 台账 $tot 条"
    foreach ($h in @($l.hooks)) {
        if ($h.action -eq 'created') {
            if (Test-Path -LiteralPath $h.path) { Write-Host ("  [X 残留] " + $h.path); $bad++ }
            else { Write-Host ("  [OK] 已删除 " + $h.path) }
        } else {
            if (-not $h.backup -or -not (Test-Path -LiteralPath $h.backup)) { Write-Host ("  [X 无备份] " + $h.path); $bad++ }
            else {
                $a = Get-Hash $h.path
                $b = Get-Hash $h.backup
                if ($a -and $b -and $a -eq $b) { Write-Host ("  [OK] 已还原 " + $h.path) }
                else { Write-Host ("  [X 未还原] " + $h.path); $bad++ }
            }
        }
    }
    if ($bad -gt 0) { Write-Host ("[verify] BAD=$bad OK=" + ($tot - $bad) + " EXPIRED=$expired"); Write-Host "[verify] 失败：$bad 项未清干净。"; exit 1 }
    Write-Host ("[verify] BAD=0 OK=$tot EXPIRED=$expired")
    if ($expired -gt 0) { Write-Host "[verify] 全绿，但有 $expired 条租约已过期未拆 —— 交给 -Collect 收尾，别等发起方。"; exit 0 }
    Write-Host "[verify] 全部通过。"
    exit 0
}

# ---------- 通用扫描 ----------
if ($Sweep) {
    if (-not $Repo) { throw "-Sweep 需要 -Repo" }
    $fatal = 0; $ask = 0
    Write-Host "[sweep] 目标：$Repo"
    $isGit = Test-Path -LiteralPath (Join-Path $Repo ".git")

    # ===== 硬残留 [X]：能确定判定的才算，返回非零 =====
    $hooksDir = Join-Path (Join-Path $Repo ".git") "hooks"
    if (Test-Path -LiteralPath $hooksDir) {
        $real = @(Get-ChildItem -LiteralPath $hooksDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.sample" })
        if ($real.Count -gt 0) {
            Write-Host ("  [X] .git/hooks 下有 $($real.Count) 个非 sample 文件（安装过的门）：")
            foreach ($f in $real) { Write-Host ("        " + $f.Name) }
            $fatal++
        } else { Write-Host "  [OK] .git/hooks 干净" }
    }

    if ($isGit) {
        # 门被改指到仓外：只看 .git/hooks 会整个漏掉
        $hp = (& git -C $Repo config --get core.hooksPath 2>$null | Out-String).Trim()
        if ($hp) { Write-Host ("  [X] core.hooksPath = $hp（门藏在仓外，须 git config --unset 并恢复原目录）"); $fatal++ }
        else { Write-Host "  [OK] core.hooksPath 未设" }

        # 临时 worktree：§4.1 明列的残留物，git 自己能数
        $wt = @((& git -C $Repo worktree list 2>$null | Where-Object { $_ -and $_.Trim() -ne '' }))
        if ($wt.Count -gt 1) {
            Write-Host ("  [X] worktree 共 $($wt.Count) 个，本流程临时建的须 git worktree remove：")
            foreach ($w in ($wt | Select-Object -Skip 1)) { Write-Host ("        " + $w) }
            $fatal++
        } else { Write-Host "  [OK] worktree 只有主工作树" }

        # 全局 git 配置里被加进来的 alias/pager/editor 之类
        $ga = @(& git config --global --get-regexp 'alias\.|core\.(pager|editor)' 2>$null | Where-Object { $_ -and $_.Trim() -ne '' })
        if ($ga.Count -gt 0) { Write-Host ("  [?] 全局 git 配置有 $($ga.Count) 项别名/pager/editor —— 确认不是本流程加的"); $ask++ }
    }

    # ===== 需人工确认 [?]：可能是用户本来就有的东西 =====
    foreach ($c in @(".mcp.json", "mcp.json", ".cursor\mcp.json", ".vscode\mcp.json")) {
        if (Test-Path -LiteralPath (Join-Path $Repo $c)) { Write-Host ("  [?] 存在 $c —— 确认里面的 server 注册是你主动要留的，否则删除"); $ask++ }
    }
    foreach ($c in @("AGENTS.md", "CLAUDE.md", ".cursorrules")) {
        if (Test-Path -LiteralPath (Join-Path $Repo $c)) { Write-Host ("  [?] 存在 $c —— 确认没有本流程自动追加的段落"); $ask++ }
    }
    # CI 门（§4.1 列了，之前一版根本没查）
    $ciFound = @()
    foreach ($c in @(".github\workflows", ".github\actions", ".gitlab-ci.yml", "azure-pipelines.yml", ".circleci\config.yml", ".travis.yml", "Jenkinsfile", ".woodpecker.yml")) {
        if (Test-Path -LiteralPath (Join-Path $Repo $c)) { $ciFound += $c }
    }
    if ($ciFound.Count -gt 0) { Write-Host ("  [?] 存在 CI 配置 " + ($ciFound -join ', ') + " —— 确认不是本流程装的门（台账里没登记就该删）"); $ask++ }

    # 环境变量文件（§4.1 列了环境变量）
    $envFound = @()
    foreach ($c in @(".env", ".env.local", ".envrc")) { if (Test-Path -LiteralPath (Join-Path $Repo $c)) { $envFound += $c } }
    if ($envFound.Count -gt 0) { Write-Host ("  [?] 存在环境变量文件 " + ($envFound -join ', ') + " —— 确认不是本流程写的（含令牌则必须删）"); $ask++ }

    foreach ($d in @(".codebase-memory", ".serena", ".repomap", ".cache\recon")) {
        if (Test-Path -LiteralPath (Join-Path $Repo $d)) { Write-Host ("  [?] 存在常驻索引目录 $d —— 若由本流程创建，必须删除"); $ask++ }
    }

    if ($isGit) {
        $st = @(git -c core.quotepath=false -C $Repo status --porcelain 2>$null | Where-Object { $_ -and $_.Trim() -ne '' })
        if ($st.Count -gt 0) {
            Write-Host ("  [?] git status 有 $($st.Count) 项变更 —— 逐项确认是否都是用户要的成果物：")
            foreach ($s in ($st | Select-Object -First 30)) { Write-Host ("        " + $s) }
            $ask++
        } else { Write-Host "  [OK] git status 干净" }
    }

    # ===== 判不了的，明说；不许让它长得像"扫过了" =====
    $unc = @('daemon / watcher', 'crontab 与计划任务', '用户级环境变量与 shell profile', '常驻端口与后台任务', '跨仓写入（只扫了 -Repo 这一个目录）')
    Write-Host ("  [未覆盖] " + ($unc -join ' / '))

    Write-Host ("[sweep] HARD=$fatal CHECK=$ask UNCOVERED=" + $unc.Count)
    if ($fatal -gt 0) { Write-Host "[sweep] 发现 $fatal 类硬残留，必须清掉才算收尾。"; exit 1 }
    if ($Strict -and ($ask -gt 0)) { Write-Host "[sweep] -Strict：$ask 项 [?] 未逐一确认，判失败。"; exit 1 }
    Write-Host "[sweep] 无硬残留（[?] $ask 项需人工确认，未覆盖 " + $unc.Count + " 类需另行核）。"
    exit 0
}

Write-Host "用法：-Register [-Owner x -TTLHours n] / -List / -Teardown [-Apply] / -Verify / -Sweep [-Strict] -Repo <路径> / -Renew / -Collect [-Apply]"
exit 2
