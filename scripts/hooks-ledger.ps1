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
    [string]$Repo
)

$ErrorActionPreference = "Stop"

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
    Write-Host "[verify] 台账 $(@($l.hooks).Count) 条"
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
    if ($bad -gt 0) { Write-Host "[verify] 失败：$bad 项未清干净。"; exit 1 }
    Write-Host "[verify] 全部通过。"
    exit 0
}

# ---------- 通用扫描 ----------
if ($Sweep) {
    if (-not $Repo) { throw "-Sweep 需要 -Repo" }
    $fatal = 0
    Write-Host "[sweep] 目标：$Repo"

    $hooksDir = Join-Path $Repo ".git\hooks"
    if (Test-Path -LiteralPath $hooksDir) {
        $real = @(Get-ChildItem -LiteralPath $hooksDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.sample" })
        if ($real.Count -gt 0) {
            Write-Host ("  [X] .git/hooks 下有 $($real.Count) 个非 sample 文件（安装过的门）：")
            foreach ($f in $real) { Write-Host ("        " + $f.Name) }
            $fatal++
        } else { Write-Host "  [OK] .git/hooks 干净" }
    }

    foreach ($c in @(".mcp.json", "mcp.json", ".cursor\mcp.json", ".vscode\mcp.json")) {
        $p = Join-Path $Repo $c
        if (Test-Path -LiteralPath $p) { Write-Host ("  [?] 存在 $c —— 确认里面的 server 注册是你主动要留的，否则删除"); }
    }

    foreach ($c in @("AGENTS.md", "CLAUDE.md", ".cursorrules")) {
        $p = Join-Path $Repo $c
        if (Test-Path -LiteralPath $p) { Write-Host ("  [?] 存在 $c —— 确认没有本流程自动追加的段落") }
    }

    foreach ($d in @(".codebase-memory", ".serena", ".repomap", ".cache\recon")) {
        $p = Join-Path $Repo $d
        if (Test-Path -LiteralPath $p) { Write-Host ("  [?] 存在常驻索引目录 $d —— 若由本流程创建，必须删除") }
    }

    if (Test-Path -LiteralPath (Join-Path $Repo ".git")) {
        $st = @(git -c core.quotepath=false -C $Repo status --porcelain 2>$null)
        Write-Host ("  [?] git status 有 $($st.Count) 项变更 —— 逐项确认是否都是用户要的成果物：")
        foreach ($s in ($st | Select-Object -First 30)) { Write-Host ("        " + $s) }
    }

    if ($fatal -gt 0) { Write-Host "[sweep] 发现 $fatal 类硬残留。"; exit 1 }
    Write-Host "[sweep] 无硬残留（[?] 项需人工确认）。"
    exit 0
}

Write-Host "用法：-Register / -List / -Teardown [-Apply] / -Verify / -Sweep -Repo <路径>"
exit 2
