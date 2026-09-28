<#
.SYNOPSIS
  check-ledger-lifecycle.ps1 —— hooks-ledger.ps1 的 14 步全生命周期断言
.DESCRIPTION
  在 %TEMP% 里造一个一次性沙箱（绝不碰真仓库），把台账工具从登记跑到拆除再跑到验证。
  含**反向用例**：文件被改写却没拆除时 -Verify 必须返回非零；.git/hooks 里有门时
  -Sweep 必须返回非零。只有正向用例的检查是恒真的，抓不到"拆除根本没生效"。
  沙箱跑完即删，不留残留。
.EXAMPLE
  powershell -NoProfile -File tests/check-ledger-lifecycle.ps1
  pwsh -NoProfile -File tests/check-ledger-lifecycle.ps1
#>
param(
    [string]$Script = "",
    [switch]$KeepSandbox
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot
if (-not $Script) { $Script = Join-Path $root "scripts\hooks-ledger.ps1" }
if (-not (Test-Path -LiteralPath $Script)) { Write-Host "找不到被测脚本: $Script"; exit 2 }
$Script = (Resolve-Path -LiteralPath $Script).Path

$sb = Join-Path ([System.IO.Path]::GetTempPath()) ("lrf-sandbox-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$repo = Join-Path $sb "repo"; $kit = Join-Path $sb "kit"
$ledger = Join-Path $kit "hooks.json"; $backup = Join-Path $kit "backup\.mcp.json"
New-Item -ItemType Directory -Force -Path (Join-Path $repo "src"), $kit, (Split-Path -Parent $backup) | Out-Null

$pass = 0; $bad = 0
# 子进程用哪个 shell：Windows 上按 5.1 测（那才是出事的环境），其它平台退回 pwsh
$sh = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
$shArgs = @('-NoProfile','-File')
if ($env:OS -eq 'Windows_NT') { $shArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File') }
function HashOf($p) { if (-not (Test-Path -LiteralPath $p)) { return "" }; (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
# 子进程写 stderr 不该掀翻 harness（git worktree/commit 都爱往 stderr 打进度）
function G([string[]]$ga) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return (& git @ga 2>&1 | Out-String) } finally { $ErrorActionPreference = $prev }
}
$gate = Join-Path (Join-Path (Join-Path $repo '.git') 'hooks') 'pre-commit'
function Step($want, $name, [string[]]$args_) {
    # 子进程往 stderr 写东西不该把整个 harness 掐死：这里临时放宽，退出码才是判据
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $sh ($shArgs + [string[]]@($Script)) @args_ 2>&1 | Out-String }
    finally { $ErrorActionPreference = $prev }
    $rc = $LASTEXITCODE
    $hit = ($rc -eq $want)
    if ($hit) { $script:pass++ } else { $script:bad++ }
    Write-Host ("  [{0}] {1,-30} rc={2} (期望 {3})" -f ($(if($hit){"OK"}else{"X"})), $name, $rc, $want)
    if (-not $hit) { ($out -split "`r?`n" | Where-Object { $_ } | Select-Object -First 5 | ForEach-Object { Write-Host ("        | " + $_) }) }
    return $out
}
try {
    # ---- 沙箱：一个 git 仓 + 一个"会被改写的配置文件" + 一个已装的 git 门 ----
    Set-Content -LiteralPath (Join-Path $repo "src\app.py") -Value "x = 1" -Encoding UTF8
    $baseline = '{"mcpServers":{}}' + [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $repo ".mcp.json") -Value $baseline.TrimEnd() -Encoding ASCII
    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    if ($gitExe) {
        G @('init','-q',$repo) | Out-Null
        G @('-C',$repo,'add','-A') | Out-Null
        G @('-C',$repo,'-c','user.email=t@t','-c','user.name=t','commit','-q','-m','seed') | Out-Null
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $gate) | Out-Null
    Set-Content -LiteralPath $gate -Value "#!/bin/sh`necho gate" -Encoding ASCII

    # 关键：备份存基线，随后把真文件改成**确实不同**的内容。
    # 若改写与基线一字不差，-Verify 报"已还原"就是真话，整条反向用例白测。
    Copy-Item -LiteralPath (Join-Path $repo ".mcp.json") -Destination $backup -Force
    $hBase = HashOf $backup
    Set-Content -LiteralPath (Join-Path $repo ".mcp.json") -Value '{"mcpServers":{"evil":{"command":"node"}}}' -Encoding ASCII
    $hDirty = HashOf (Join-Path $repo ".mcp.json")
    if ($hBase -eq $hDirty) { Write-Host "  [X] 夹具失效：改写后与基线同哈希，反向用例无从成立"; exit 1 }
    Write-Host ("[lifecycle] 脚本 = {0}" -f $Script)
    Write-Host ("[lifecycle] 夹具真值：基线 {0} / 改写 {1}" -f $hBase.Substring(0,16), $hDirty.Substring(0,16))

    Step 0  "1 干净态 Verify"        @('-Ledger', $ledger, '-Verify') | Out-Null
    Step 0  "2 Register modified"    @('-Ledger', $ledger, '-Register','-Kind','config','-Path',(Join-Path $repo ".mcp.json"),'-Action','modified','-Backup',$backup) | Out-Null
    Step 1  "3 未拆除 Verify 应拦"    @('-Ledger', $ledger, '-Verify') | Out-Null
    Step 0  "4 Teardown 预演"        @('-Ledger', $ledger, '-Teardown') | Out-Null
    if ((HashOf (Join-Path $repo ".mcp.json")) -ne $hDirty) { Write-Host "  [X] 预演改了东西（不该改）"; $bad++ } else { Write-Host "  [OK] 预演未动文件"; $pass++ }
    Step 0  "5 Teardown -Apply"      @('-Ledger', $ledger, '-Teardown','-Apply') | Out-Null
    if ((HashOf (Join-Path $repo ".mcp.json")) -eq $hBase) { Write-Host "  [OK] 文件真还原成基线"; $pass++ } else { Write-Host "  [X] 声称拆了，哈希却对不上"; $bad++ }
    Step 0  "6 拆后 Verify 应绿"      @('-Ledger', $ledger, '-Verify') | Out-Null

    # created 类：拆除 = 真删
    $dir = Join-Path $kit "scratch-dir"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Step 0  "7 Register created dir" @('-Ledger', $ledger, '-Register','-Kind','dir','-Path',$dir,'-Action','created') | Out-Null
    Step 1  "8 未拆 created 应拦"     @('-Ledger', $ledger, '-Verify') | Out-Null
    Step 0  "9 Teardown -Apply"      @('-Ledger', $ledger, '-Teardown','-Apply') | Out-Null
    if (Test-Path -LiteralPath $dir) { Write-Host "  [X] 台账说拆了，目录还在"; $bad++ } else { Write-Host "  [OK] 目录真被删"; $pass++ }
    Step 0  "10 拆后 Verify"          @('-Ledger', $ledger, '-Verify') | Out-Null
    $lst = Step 0 "11 List"           @('-Ledger', $ledger, '-List')
    # 这里只断言**条数与路径**，不断言中文：自检进程自己设过 UTF-8 码页，而
    # SetConsoleOutputCP 作用于整个控制台，子进程继承之后"没守卫也能出对的中文"，
    # 拿 '已拆' 这种字样当判据就是恒真。守卫本身由 check-encoding.ps1 按字节查。
    $listed = @($lst -split "`r?`n" | Where-Object { $_ -match '\.mcp\.json|scratch-dir' })
    if ($listed.Count -eq 2) { Write-Host "  [OK] List 列出 2 条"; $pass++ } else { Write-Host "  [X] List 只列出 $($listed.Count) 条（期望 2）"; $bad++ }
    Step 1  "12 Sweep 见 git 门应拦"  @('-Ledger', $ledger, '-Sweep','-Repo',$repo) | Out-Null
    Remove-Item -LiteralPath $gate -Force
    Step 0  "13 Sweep 清门后应绿"     @('-Ledger', $ledger, '-Sweep','-Repo',$repo) | Out-Null
    Step 2  "14 无子命令给用法"        @('-Ledger', $ledger) | Out-Null

    # ===== 21~27：租约与孤儿收集器（"发起方死了也要有人收"这条不变量）=====
    $lz = Join-Path $kit "lease.json"
    $lDir = Join-Path $kit "lease-dir"
    $lNoTtl = Join-Path $kit "no-ttl-dir"
    New-Item -ItemType Directory -Force -Path $lDir, $lNoTtl | Out-Null
    Step 0 "21 Register 带 TTL 2h" @('-Ledger', $lz, '-Register','-Kind','dir','-Path',$lDir,'-Action','created','-Owner','t-lease','-TTLHours','2') | Out-Null
    Step 0 "22 Register 不带 TTL"   @('-Ledger', $lz, '-Register','-Kind','dir','-Path',$lNoTtl,'-Action','created','-Owner','t-nottl') | Out-Null
    # 被测件不认租约参数时（如 v1.1），Register 会失败、台账根本不会落盘。
    # 这时候必须**整块判失败并继续**，不能让后面的读文件把 harness 崩掉——崩了会掩盖剩余检查。
    if (-not (Test-Path -LiteralPath $lz)) {
        Write-Host "  [X] 租约登记没落盘（被测件不认 -TTLHours/-Owner？）—— 21~27 整块计失败，继续跑收尾项"
        $bad += 6
    } else {
    $lj = Get-Content -LiteralPath $lz -Raw -Encoding UTF8 | ConvertFrom-Json
    $withExp = @($lj.hooks | Where-Object { $_.expires })
    $noExp = @($lj.hooks | Where-Object { -not $_.expires })
    if ($withExp.Count -eq 1 -and $noExp.Count -eq 1) { Write-Host "  [OK] 租约字段按预期落盘（1 条带 expires、1 条不带）"; $pass++ }
    else { Write-Host "  [X] 租约字段没写对（带 expires $($withExp.Count) / 不带 $($noExp.Count)，应为 1/1）"; $bad++ }

    $o = Step 0 "23 未过期 Collect" @('-Ledger', $lz, '-Collect')
    if ($o -match 'ORPHAN=0' -and (Test-Path -LiteralPath $lDir)) { Write-Host "  [OK] 未过期不算孤儿，目录还在"; $pass++ }
    else { Write-Host "  [X] 未过期就被当孤儿了"; $bad++ }

    # 造过期：把带租约那两条的 expires 挪到一小时前（测过期不能靠真等）
    $past = (Get-Date).AddHours(-1).ToString('s')
    $lj = Get-Content -LiteralPath $lz -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($h in @($lj.hooks)) { if ($h.owner -eq 't-lease') { $h.expires = $past } }
    ($lj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $lz -Encoding UTF8

    $o = Step 0 "24 过期 Collect 干跑" @('-Ledger', $lz, '-Collect')
    if ($o -match 'ORPHAN=1' -and $o -match 'APPLIED=0' -and (Test-Path -LiteralPath $lDir)) {
        Write-Host "  [OK] 干跑只报不删（ORPHAN=1 APPLIED=0，目录仍在）"; $pass++ }
    else { Write-Host "  [X] 干跑改动了东西或没认出租户（输出见上）"; $bad++ }
    $o = Step 1 "25 过期条目 Verify" @('-Ledger', $lz, '-Verify')
    if ($o -match 'EXPIRED=1') { Write-Host "  [OK] Verify 把过期未拆计入 EXPIRED="; $pass++ }
    else { Write-Host "  [X] Verify 没报出过期条目"; $bad++ }

    $o = Step 0 "26 -Renew 续租" @('-Ledger', $lz, '-Renew','-Owner','t-lease','-TTLHours','5')
    $o = Step 0 "26b 续租后 Collect" @('-Ledger', $lz, '-Collect')
    if ($o -match 'ORPHAN=0' -and (Test-Path -LiteralPath $lDir)) { Write-Host "  [OK] 续租后不再是孤儿"; $pass++ }
    else { Write-Host "  [X] 续租没起作用"; $bad++ }

    # 再让它过期，然后 -Apply 真拆
    $lj = Get-Content -LiteralPath $lz -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($h in @($lj.hooks)) { if ($h.owner -eq 't-lease') { $h.expires = $past } }
    ($lj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $lz -Encoding UTF8
    Step 0 "27 Collect -Apply" @('-Ledger', $lz, '-Collect','-Apply') | Out-Null
    if (-not (Test-Path -LiteralPath $lDir)) { Write-Host "  [OK] 过期孤儿被真删"; $pass++ }
    else { Write-Host "  [X] -Apply 跑完目录还在，收集器没落地"; $bad++ }
    # ★ 一票否决项：没设租约的条目，无论别人怎么过期都不许被碰
    if (Test-Path -LiteralPath $lNoTtl) { Write-Host "  [OK] 无租约条目未被收集（误删一票否决项通过）"; $pass++ }
    else { Write-Host "  [X] 无租约条目被收集器删了 —— 这是不可接受的误删"; $bad++ }
    }   # ← 租约块（Test-Path $lz）的 else 收尾

    # ===== 15~20：-Sweep 覆盖面（SKILL.md §4.1 列的 CI / 环境变量 / worktree / hooksPath）=====
    # 计数一律看**增量**：沙箱里本来就挂着 .mcp.json 等 [?] 项，猜绝对值必错。
    function Sweep($extra) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $txt = & $sh ($shArgs + [string[]]@($Script, '-Ledger', $ledger, '-Sweep', '-Repo', $repo) + [string[]]$extra) 2>&1 | Out-String
            $rc = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prev }
        if ($txt -match 'HARD=(\d+) CHECK=(\d+) UNCOVERED=(\d+)') {
            return [pscustomobject]@{ rc = $rc; hard = [int]$matches[1]; check = [int]$matches[2]; uncov = [int]$matches[3]; txt = $txt }
        }
        return [pscustomobject]@{ rc = -9; hard = -1; check = -1; uncov = -1; txt = $txt }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repo ".git"))) {
        Write-Host "  [SKIP] 15~20 需要沙箱 git 仓（本机无 git）"
    } else {
        $base = Sweep @()
        if ($base.hard -ge 0) { Write-Host "  [OK] 15 汇总行可解析（HARD=$($base.hard) CHECK=$($base.check) UNCOVERED=$($base.uncov)）"; $pass++ }
        else { Write-Host "  [X] 15 Sweep 没打 ASCII 汇总行 HARD=/CHECK=/UNCOVERED= —— 上层无法机器读数"; $bad++ }
        if ($base.uncov -ge 1) { Write-Host "  [OK] 15b 未覆盖类别被明写（$($base.uncov) 类）"; $pass++ }
        else { Write-Host "  [X] 15b 未覆盖声明消失 —— 会把'判不了'伪装成'扫过了'"; $bad++ }
        # 回归：v1.2 曾把人读行写成 `"...未覆盖 " + $unc.Count + " 类..."`，
        # 参数模式里的 + 不参与拼接，于是打印出字面量 `+ 5 +`。这条断言纯 ASCII，不受码页影响。
        if ($base.txt -match '\s\+\s') { Write-Host "  [X] 15c 人读输出里漏出字面量 ' + '（参数模式拼接错误）"; $bad++ }
        else { Write-Host "  [OK] 15c 人读输出无字面量 '+'"; $pass++ }

        # CI 配置 + 环境变量文件：§4.1 列了，之前一版根本没查
        New-Item -ItemType Directory -Force -Path (Join-Path $repo ".github\workflows") | Out-Null
        Set-Content -LiteralPath (Join-Path $repo ".github\workflows\ci.yml") -Value "on: push`njobs: {}" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $repo ".env") -Value "TOKEN=***" -Encoding ASCII
        $withCi = Sweep @()
        if ($withCi.check -gt $base.check) { Write-Host "  [OK] 16 CI/.env 被计入 [?]（$($base.check)→$($withCi.check)）"; $pass++ }
        else { Write-Host "  [X] 16 种了 CI 配置和 .env，CHECK 却没涨（$($base.check)→$($withCi.check)）—— 这两类仍没被扫"; $bad++ }
        $strictRun = Sweep @('-Strict')
        if ($strictRun.rc -eq 1) { Write-Host "  [OK] 17 -Strict 下未确认的 [?] 判失败（rc=1）"; $pass++ }
        else { Write-Host "  [X] 17 -Strict 没起作用（rc=$($strictRun.rc)）"; $bad++ }

        # core.hooksPath：门被改指到仓外，只看 .git/hooks 会整个漏掉
        G @('-C',$repo,'config','core.hooksPath',$kit) | Out-Null
        $withHp = Sweep @()
        if ($withHp.hard -gt $base.hard -and $withHp.rc -eq 1) { Write-Host "  [OK] 18 core.hooksPath 被算硬残留（HARD=$($withHp.hard), rc=1）"; $pass++ }
        else { Write-Host "  [X] 18 core.hooksPath 没被逮住（HARD=$($withHp.hard) vs 基线 $($base.hard), rc=$($withHp.rc)）"; $bad++ }
        G @('-C',$repo,'config','--unset','core.hooksPath') | Out-Null

        # 临时 worktree：§4.1 明列
        G @('-C',$repo,'worktree','add',"$sb\wt-extra",'-b','wt-extra') | Out-Null
        $withWt = Sweep @()
        if ($withWt.hard -gt $base.hard -and $withWt.rc -eq 1) { Write-Host "  [OK] 19 临时 worktree 被算硬残留（HARD=$($withWt.hard), rc=1）"; $pass++ }
        else { Write-Host "  [X] 19 多出一个 worktree 却没被逮住（HARD=$($withWt.hard) vs $($base.hard), rc=$($withWt.rc)）"; $bad++ }
        G @('-C',$repo,'worktree','remove',"$sb\wt-extra",'--force') | Out-Null
        G @('-C',$repo,'branch','-D','wt-extra') | Out-Null

        # 全清干净后必须回到基线，否则上面那些"涨了"的判据没意义
        Remove-Item -LiteralPath (Join-Path $repo ".env") -Force
        Remove-Item -LiteralPath (Join-Path $repo ".github") -Recurse -Force
        G @('-C',$repo,'add','-A') | Out-Null
        G @('-C',$repo,'-c','user.email=t@t','-c','user.name=t','commit','-q','-m','clean') | Out-Null
        $after = Sweep @()
        if ($after.hard -eq 0 -and $after.rc -eq 0) { Write-Host "  [OK] 20 清干净后 HARD=0 且 rc=0"; $pass++ }
        else { Write-Host "  [X] 20 清完仍报 HARD=$($after.hard) rc=$($after.rc) —— 有判定不会回落"; $bad++ }
    }
} finally {
    if ($KeepSandbox) { Write-Host "[lifecycle] 沙箱留着：$sb" }
    elseif (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
}
Write-Host ("")
if ($bad -gt 0) { Write-Host "[lifecycle] 失败 $bad 项 / 通过 $pass 项"; exit 1 }
Write-Host "[lifecycle] 全部通过（$pass 项）。"
exit 0
