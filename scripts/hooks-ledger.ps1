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
#>
param(
    [Parameter(Mandatory = $true)][string]$Ledger,
    [switch]$Register,
    [ValidateSet('file','dir','config','process','env','other')][string]$Kind = 'file',
    [string]$Path,
    [ValidateSet('created','modified','appended')][string]$Action = 'created',
    [string]$Backup,
    [string]$Note = "",
    [switch]$List,
    [switch]$Teardown,
    [switch]$Apply,
    [switch]$Verify,
    [switch]$Sweep,
    [switch]$Strict,
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

# ---------- 登记 ----------
if ($Register) {
    if (-not $Path) { throw "登记需要 -Path" }
    if ($Action -ne 'created' -and -not $Backup) { throw "-Action $Action 必须同时给 -Backup，否则无法恢复" }
    $full = [System.IO.Path]::GetFullPath($Path)
    $b = ""
    if ($Backup) { $b = [System.IO.Path]::GetFullPath($Backup) }
    $l = Load-Ledger $Ledger
    $entry = [pscustomobject]@{
        ts           = (Get-Date -Format 's')
        kind         = $Kind
        path         = $full
        action       = $Action
        backup       = $b
        originalHash = (Get-Hash $b)
        note         = $Note
        removed      = $false
    }
    $l.hooks = @($l.hooks) + $entry
    Save-Ledger $l $Ledger
    Write-Host "[ledger] 已登记：$Action / $Kind / $full"
    if ($b) { Write-Host "[ledger] 备份：$b" }
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
        Write-Host ("  [{0}] {1,-8} {2,-10} {3}" -f $state, $h.action, $h.kind, $h.path)
    }
    exit 0
}

# ---------- 预演 / 拆除 ----------
if ($Teardown) {
    $l = Load-Ledger $Ledger
    $pending = @($l.hooks | Where-Object { -not $_.removed })
    if ($pending.Count -eq 0) { Write-Host "[teardown] 台账为空或已全部拆除。"; exit 0 }
    if ($Apply) { Write-Host "[teardown] 执行拆除，共 $($pending.Count) 项" } else { Write-Host "[teardown] 预演模式（不改动任何东西），共 $($pending.Count) 项。加 -Apply 执行。" }
    foreach ($h in $pending) {
        if ($h.action -eq 'created') {
            if (Test-Path -LiteralPath $h.path) {
                Write-Host ("  [删除] " + $h.path)
                if ($Apply) { Remove-Item -LiteralPath $h.path -Recurse -Force; $h.removed = $true }
            } else {
                Write-Host ("  [跳过] 已不存在：" + $h.path)
                if ($Apply) { $h.removed = $true }
            }
        } else {
            if (-not $h.backup -or -not (Test-Path -LiteralPath $h.backup)) {
                Write-Warning ("  [无法恢复] 缺备份：" + $h.path)
            } else {
                Write-Host ("  [恢复] " + $h.path + "  <=  " + $h.backup)
                if ($Apply) { Copy-Item -LiteralPath $h.backup -Destination $h.path -Force; $h.removed = $true }
            }
        }
    }
    if ($Apply) { Save-Ledger $l $Ledger; Write-Host "[teardown] 执行完毕。请运行 -Verify 验证。" }
    exit 0
}

# ---------- 验证 ----------
if ($Verify) {
    $l = Load-Ledger $Ledger
    $bad = 0
    $tot = @($l.hooks).Count
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
    if ($bad -gt 0) { Write-Host ("[verify] BAD=$bad OK=" + ($tot - $bad)); Write-Host "[verify] 失败：$bad 项未清干净。"; exit 1 }
    Write-Host ("[verify] BAD=0 OK=$tot")
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

Write-Host "用法：-Register / -List / -Teardown [-Apply] / -Verify / -Sweep [-Strict] -Repo <路径>"
exit 2
