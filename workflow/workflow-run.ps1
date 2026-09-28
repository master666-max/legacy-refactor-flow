<#
.SYNOPSIS
  workflow-run.ps1 —— 按 legacy-refactor-flow.workflow.json 跑五步流程：判门、记证据、出密封
.DESCRIPTION
  为什么要有它：SKILL.md 是给 agent 读的文字，文字管不住「我觉得这步差不多了」。
  本执行器把每个阶段出口变成一道可执行的门，过不去就停，并把这次跑的东西**密封**成
  三份语义文档 + 一份人读投影，交给不在场的人复核。

  产物落在被检仓之外（~/.legacy-refactor-flow/runs/<projectId>/<runId>/），理由有两条：
  跑一次重构侦察不该让目标仓 git status 变脏；验收证据不该装在被验收的东西里面。
    run-manifest.json   本次跑的身份：目标、输入、三个脚本的 sha256、阶段清单
    gates.json          每一条门的判据、解析后的目标、verdict、实测退出码
    coverage.json       每阶段状态（complete/partial/unknown/failed）+ 未核项 + 名额截断留下的 unknown
    report.md           人读投影，**不入密封**
    seal.json           前三份的 sha256 —— 密封只证明本地文档没被改过，不是签名、不是发布者身份、
                        不证明运行时加载过哪个版本
  人工门（op=human）必须由 -Confirm <phaseId> 显式放行；没放行 ⇒ 该阶段 partial ⇒ 整体只出 INCONCLUSIVE。
  任一门 partial/failed ⇒ 退出码非零，且不得声称「改好了」。

  与密封式扫描工具的差别（诚实声明）：本执行器是**单进程前台**跑的，没有常驻 job 通道，
  所以没有 running/cancel_requested 六态与协作取消；只读状态用 `-RunDir`（不带 `-RepoPath`）——
  那读的是已落盘的密封产物，不是进度条。
.EXAMPLE
  powershell -NoProfile -File workflow/workflow-run.ps1 -RepoPath D:\my\legacy -TestCmd "node --test all.test.js" -DryRun
  powershell -NoProfile -File workflow/workflow-run.ps1 -RepoPath D:\my\legacy -TestCmd "py -3 check.py" -Confirm A,B,C,D,E,T
  powershell -NoProfile -File workflow/workflow-run.ps1 -VerifySeal -RunDir C:\Users\me\.legacy-refactor-flow\runs\legacy-1a2b3c4d\20260928-1130
#>
param(
    [string]$RepoPath = "",
    [string]$TestCmd = "",
    [string]$Manifest = "",
    [string]$Profile = "",
    [string]$KitDir = "",
    [string]$MutationTargets = "",
    [int]$MaxMutants = 0,
    [int]$LeaseTTLHours = 0,
    [string]$Owner = "workflow",
    [string]$FromPhase = "",
    [string[]]$Confirm = @(),
    [switch]$DryRun,
    [switch]$VerifySeal,
    [string]$RunDir = "",
    [switch]$InRepo
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
# -Confirm 的两种给法都要能吃：在 -Command 里 `A,C` 由 PowerShell 解析成数组，
# 在 -File 里 argv 是逐个原样传入，'A,C,D' 会变成**一个**字符串元素 ⇒  Contains 全不命中，
# 人工门静默不落账、整体只出 INCONCLUSIVE。这里统一按逗号再切一刀。
$Confirm = @($Confirm | ForEach-Object { "$_".Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$skillRoot = Split-Path -Parent $PSScriptRoot
if (-not $Manifest) { $Manifest = Join-Path $PSScriptRoot "legacy-refactor-flow.workflow.json" }
if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Host "[wf] 清单不存在：$Manifest —— 这是注册/安装故障，不是流程失败。停止。"
    exit 2
}
$mf = [System.IO.File]::ReadAllText($Manifest, [System.Text.Encoding]::UTF8).Replace([string][char]0xFEFF, "") | ConvertFrom-Json

function Sha256Of([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

# ---------- 只读观察者：核对既有密封 ----------
if ($VerifySeal) {
    if (-not $RunDir -or -not (Test-Path -LiteralPath $RunDir)) { Write-Host "[seal] -VerifySeal 需要一个存在的 -RunDir"; exit 2 }
    $sj = Join-Path $RunDir "seal.json"
    if (-not (Test-Path -LiteralPath $sj)) { Write-Host "[seal] 无 seal.json"; exit 1 }
    $seal = [System.IO.File]::ReadAllText($sj, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $bad = 0
    foreach ($e in @($seal.files)) {
        $p = Join-Path $RunDir $e.name
        if (-not (Test-Path -LiteralPath $p)) { Write-Host ("  [X 缺文件] " + $e.name); $bad++; continue }
        $now = Sha256Of $p
        if ($now -eq $e.sha256) { Write-Host ("  [OK] " + $e.name) } else { Write-Host ("  [X 已被改动] " + $e.name); $bad++ }
    }
    if ($bad -gt 0) { Write-Host "[seal] 密封破坏：$bad 项"; exit 1 }
    Write-Host "[seal] 三份语义文档与密封一致。"
    exit 0
}
if ($RunDir -and -not $RepoPath) {
    $rmf = Join-Path $RunDir "run-manifest.json"
    if (Test-Path -LiteralPath $rmf) {
        $o = [System.IO.File]::ReadAllText($rmf, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        Write-Host ("[status] run " + $o.runId + " 目标 " + $o.repo + " 结论 " + $o.outcome + " 停在 " + $o.failAt)
        $st = Join-Path $RunDir "coverage.json"
        if (Test-Path -LiteralPath $st) {
            $cv = [System.IO.File]::ReadAllText($st, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($p in @($cv.phases)) { Write-Host ("  {0} {1} {2}" -f $p.phase, $p.status, $p.note) }
        }
    }
    exit 0
}
if (-not $RepoPath) { Write-Host "[wf] 需要 -RepoPath"; exit 2 }
if (-not (Test-Path -LiteralPath $RepoPath)) { throw "路径不存在: $RepoPath" }
$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$kit = if ($KitDir) { $KitDir } else { $mf.inputs.kitDir.default }
$mutT = if ($MutationTargets) { $MutationTargets } else { $mf.inputs.mutationTargets.default }
$mutN = if ($MaxMutants -gt 0) { $MaxMutants } else { [int]$mf.inputs.maxMutants.default }
if (-not $Profile) { $Profile = $mf.inputs.profile.default }
if (-not ($mf.profiles.PSObject.Properties.Name -contains $Profile)) { Write-Host "[wf] 未知 profile $Profile"; exit 2 }
$prof = $mf.profiles.$Profile
# -FromPhase 不许写死成 A：profile=gate 的阶段表里没有 A，写死会让它开箱即 rc=2（实测踩过）。
# 默认取本 profile 的第一个阶段；要中途续跑才显式给。
if (-not $FromPhase) { $FromPhase = @($prof.phases)[0] }
if (-not $DryRun -and -not $TestCmd) { Write-Host "[wf] 跑机器门需要 -TestCmd"; exit 2 }

# ---------- run 目录（默认落在被检仓之外）----------
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
# 项目指纹：对**路径字符串**算 SHA-256（不是文件，别用 Get-FileHash）
$sha = [System.Security.Cryptography.SHA256]::Create()
$pidHash = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($repo)))).Replace('-', '').Substring(0, 8).ToLower()
$projectId = (Split-Path $repo -Leaf) + '-' + $pidHash
if ($InRepo) { $runRoot = Join-Path (Join-Path $repo $kit) ("runs/" + $runId) }
elseif ($RunDir) { $runRoot = $RunDir }
else { $runRoot = Join-Path (Join-Path $env:USERPROFILE ".legacy-refactor-flow\runs") ($projectId + '\' + $runId) }
$runDirOut = $runRoot
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $runDirOut | Out-Null }
if (-not $LeaseTTLHours -and $mf.inputs.leaseTTLHours) { $LeaseTTLHours = [int]$mf.inputs.leaseTTLHours.default }

$tools = [ordered]@{
    'phase0-recon'      = (Join-Path $skillRoot "scripts\phase0-recon.ps1")
    'mutation-probe'    = (Join-Path $skillRoot "scripts\mutation-probe.ps1")
    'hooks-ledger'      = (Join-Path $skillRoot "scripts\hooks-ledger.ps1")
    'testability-scan'  = (Join-Path $skillRoot "scripts\testability-scan.ps1")
}
function Sub([string]$s) {
    if (-not $s) { return $s }
    # 注意：PS 不接受"点号开头的续行"（C# 那套写法在这里会解析成两条语句）
    $t = $s.Replace('{repoPath}', $repo)
    $t = $t.Replace('{kitDir}', $kit)
    $t = $t.Replace('{testCmd}', $TestCmd)
    $t = $t.Replace('{mutationTargets}', $mutT)
    $t = $t.Replace('{maxMutants}', "$mutN")
    $t = $t.Replace('{runDir}', $runDirOut)
    return $t
}
function AbsPath([string]$p) {
    $q = Sub $p
    if ([System.IO.Path]::IsPathRooted($q)) { return $q }
    return (Join-Path $repo $q)
}
function Tail([string]$s, [int]$n) {
    if (-not $s) { return '' }
    $ls = @($s -split "`r?`n" | Where-Object { "$_".Trim() -ne '' })
    if ($ls.Count -le $n) { return ($ls -join ' ⏎ ') }
    return ('… ' + (($ls | Select-Object -Last $n) -join ' ⏎ '))
}
function Invoke-Cmd([string]$line) {
    if ($DryRun) { return @{ rc = 0; out = '(dry-run)' } }
    # 子进程工作目录必须是**被检仓**：{testCmd}（如 node --test strong/all.test.js）与
    # -OutFile "{kitDir}/…" 都是仓内相对路径；继承本执行器的 CWD 会把产物写进技能仓。
    # （不用脚本块包一层：`& $block` 在子作用域里执行，里面的赋值传不回来 —— 实测过。）
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o = ''; $rc = 0
    Push-Location -LiteralPath $repo
    try { $o = & $env:ComSpec /c $line 2>&1 | Out-String; $rc = $LASTEXITCODE }
    finally { Pop-Location; $ErrorActionPreference = $prev }
    return @{ rc = $rc; out = $o }
}
function Invoke-ToolRun([string]$name, [string[]]$argv) {
    if (-not $tools.Contains($name)) { return @{ rc = 99; out = "未知工具 $name" } }
    $exe = $tools[$name]
    if (-not (Test-Path -LiteralPath $exe)) { return @{ rc = 99; out = "找不到 $exe（注册/安装故障）" } }
    $sh = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
    $shArgs = if ($env:OS -eq 'Windows_NT') { @('-NoProfile','-ExecutionPolicy','Bypass','-File') } else { @('-NoProfile','-File') }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $o = ''; $rc = 0
    Push-Location -LiteralPath $repo
    try {
        if ($DryRun) { $o = "(dry-run) $exe $($argv -join ' ')"; $rc = 0 }
        else { $o = & $sh ($shArgs + [string[]]@($exe) + $argv) 2>&1 | Out-String; $rc = $LASTEXITCODE }
    } finally { Pop-Location; $ErrorActionPreference = $prev }
    return @{ rc = $rc; out = $o }
}

$gates = New-Object System.Collections.Generic.List[object]
$cov = New-Object System.Collections.Generic.List[object]
$unknown = New-Object System.Collections.Generic.List[object]
$deferred = New-Object System.Collections.Generic.List[object]
$failAt = ''; $exitCode = 0; $outcome = 'complete'
$started = $false

Write-Host "[wf] 清单 $($mf.name) v$($mf.version) profile=$Profile"
Write-Host "[wf] 目标 $repo"
# 注意：Write-Host "a" + $b 会把 + 当**参数**原样打印（逗号与 + 的绑定都比函数实参紧），必须整体插值
$inRepoTag = if ($InRepo) { "  (★ InRepo：产物写进被检仓，默认不这样)" } else { "" }
$dryTag = if ($DryRun) { "  (dry-run：不建目录、不落盘，机器门一律记 planned ⇒ rc 只代表接线，不代表结论)" } else { "" }
Write-Host "[wf] run  $runDirOut$inRepoTag$dryTag"
if (-not $DryRun) { $kd = Join-Path $repo $kit; if (-not (Test-Path -LiteralPath $kd)) { New-Item -ItemType Directory -Force -Path $kd | Out-Null } }

foreach ($ph in $mf.phases) {
    if ($prof.phases -notcontains $ph.id) {
        $cov.Add([pscustomobject]@{ phase = $ph.id; status = 'skipped-by-profile'; note = "profile $Profile 不含该阶段" })
        continue
    }
    if (-not $started -and $ph.id -ne $FromPhase) { continue }
    $started = $true
    Write-Host ""
    Write-Host ("══════ {0} {1} —— {2}" -f $ph.id, $ph.name, $ph.goal)
    $phaseFail = ''; $dNote = ''; $stepFail = ''
    foreach ($st in @($ph.steps)) {
        if ($st.kind -eq 'manual') { Write-Host ("  [待办·人] " + (Sub $st.desc)); continue }
        if ($st.kind -eq 'cmd') {
            $r = Invoke-Cmd (Sub $st.cmd)
            Write-Host ("  [跑] " + (Sub $st.desc) + " → rc=" + $r.rc)
            $ev = Tail $r.out 6
            if ($r.rc -ne 0 -and $ev) { Write-Host ("        输出尾部: " + $ev) }
            if ($r.rc -ne 0 -and -not $stepFail) { $stepFail = (Sub $st.desc) + "（rc=" + $r.rc + "）" }
            $gates.Add([pscustomobject]@{ phase = $ph.id; kind = 'step'; id = $st.desc; op = 'cmd'; target = Sub $st.cmd; verdict = $(if ($r.rc -eq 0) {'pass'} else {'fail'}); detail = $ev; rc = $r.rc; at = (Get-Date -Format 's') })
        } else {
            $argv = @($st.args | ForEach-Object { Sub $_ })
            $r = Invoke-ToolRun $st.tool $argv
            Write-Host ("  [跑] {0} → rc={1}" -f $st.tool, $r.rc)
            $ev = Tail $r.out 6
            if ($r.rc -ne 0 -and $ev) { Write-Host ("        输出尾部: " + $ev) }
            $gates.Add([pscustomobject]@{ phase = $ph.id; kind = 'step'; id = $st.tool; op = 'tool'; target = ($argv -join ' '); verdict = $(if ($r.rc -eq 0) {'pass'} else {'fail'}); detail = $ev; rc = $r.rc; at = (Get-Date -Format 's') })
            if ($r.rc -ne 0 -and -not $stepFail) { $stepFail = $st.tool + "（rc=" + $r.rc + "）" }
        }
    }
    foreach ($g in @($ph.gates)) {
        $verdict = 'pass'; $detail = ''; $rc = 0
        if ($g.op -eq 'human') {
            if ($Confirm -contains $ph.id) { $detail = "已由 -Confirm $($ph.id) 放行" }
            else { $verdict = 'wait'; $detail = "需人工确认后加 -Confirm $($ph.id)" }
        } elseif ($DryRun) { $verdict = 'planned'; $detail = 'dry-run' }
        elseif ($g.op -eq 'exists' -or $g.op -eq 'nonempty') {
            $p = AbsPath $g.path
            if (-not (Test-Path -LiteralPath $p)) { $verdict = 'fail'; $detail = "文件不存在 $p" }
            elseif ($g.op -eq 'nonempty' -and (Get-Item -LiteralPath $p).Length -eq 0) { $verdict = 'fail'; $detail = '空文件' }
            else { $detail = $p }
        } elseif ($g.op -eq 'matches' -or $g.op -eq 'notMatches') {
            $p = AbsPath $g.path
            if (-not (Test-Path -LiteralPath $p)) { $verdict = 'fail'; $detail = "文件不存在，$($g.op) 不白送绿：$p" }
            else {
                $txt = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
                $hit = ($txt -match (Sub $g.pattern))
                if ($g.op -eq 'matches' -and -not $hit) { $verdict = 'fail'; $detail = "没找到 /$($g.pattern)/" }
                elseif ($g.op -eq 'notMatches' -and $hit) { $verdict = 'fail'; $detail = "出现了 /$($g.pattern)/" }
                else { $detail = "判过 /$($g.pattern)/" }
            }
        } elseif ($g.op -eq 'cmd') {
            $r = Invoke-Cmd (Sub $g.cmd); $rc = $r.rc
            if ($rc -ne 0) { $verdict = 'fail'; $detail = "rc=$rc ｜ " + (Tail $r.out 6) } else { $detail = 'rc=0' }
        } elseif ($g.op -eq 'tool') {
            $argv = @($g.args | ForEach-Object { Sub $_ })
            $r = Invoke-ToolRun $g.tool $argv; $rc = $r.rc
            if ($rc -ne 0) { $verdict = 'fail'; $detail = "$($g.tool) rc=$rc ｜ " + (Tail $r.out 6) } else { $detail = "$($g.tool) rc=0" }
        } else { $verdict = 'fail'; $detail = "未知门类型 $($g.op)" }

        $gates.Add([pscustomobject]@{ phase = $ph.id; kind = 'gate'; id = $g.id; op = $g.op; target = $(if ($g.path) { Sub $g.path } elseif ($g.pattern) { Sub $g.pattern } else { Sub $g.desc }); verdict = $verdict; detail = $detail; rc = $rc; at = (Get-Date -Format 's') })
        if ($verdict -eq 'pass') { Write-Host ("  [门 {0}] 过  {1}" -f $g.id, (Sub $g.desc)) }
        elseif ($verdict -eq 'planned') { Write-Host ("  [门 {0}] 计划  {1}" -f $g.id, (Sub $g.desc)) }
        else {
            Write-Host ("  [门 {0}] {1}  {2}" -f $g.id, $(if ($verdict -eq 'wait') { '待人工' } else { '不过' }), (Sub $g.desc))
            Write-Host ("        " + $detail)
            if (-not $phaseFail) { $phaseFail = "$($ph.id)/$($g.id)" }
            if ($verdict -eq 'wait') { $exitCode = 3 } else { $exitCode = 1 }
            break
        }
    }
    if (-not $DryRun -and -not $phaseFail -and $stepFail) {
        # 门全过但步骤非零 ⇒ 不许报"全门通过"。实发形状：探针 rc=3（一个候选点都没采到）时整阶段长得像成功，
        # 最后靠 D-g1"报告文件不存在"间接发现 —— 那是巧合，不是判据。
        $phaseFail = "step:$stepFail"; $exitCode = 1
        Write-Host ("  [阶段] 门没判失败，但步骤非零：$stepFail ⇒ 本阶段判不过")
    }
    if ($ph.id -eq 'D' -and -not $DryRun) {
        # 从强度报告里取机器读数：uncov>0 记 unknown（缺席不许当已解决），并把得分钉进 coverage
        $mp = AbsPath '{runDir}/mutation-report.md'
        if (Test-Path -LiteralPath $mp) {
            $mt = [System.IO.File]::ReadAllText($mp, [System.Text.Encoding]::UTF8)
            if ($mt -match 'score=([0-9.]+) killed=(\d+) total=(\d+).*avail=(\d+) uncov=(\d+)') {
                $sc = $matches[1]; $av = [int]$matches[4]; $uc = [int]$matches[5]
                $dNote = "score=$sc（$av 个候选点里采到 $($av - $uc)）"
                if ($uc -gt 0) { $unknown.Add("裁判强度：$uc 个候选点本轮未采到 ⇒ score=$sc 是**抽样分**，不代表全仓") }
                # 跑裁判的代价：测试命令是靶仓自己的，它可能往本机 TEMP 写件，而探针会重跑它 N+1 遍。
                # 拆除阶段只看登记过的写入域 ⇒ 这类件必须记 unknown，不许当"已拆干净"。
                if ($mt -match 'temp-new=(\d+)') {
                    $tn = [int]$matches[1]
                    if ($tn -gt 0) { $unknown.Add("跑裁判的代价：本轮跑测试期间 TEMP 新增 $tn 个非探针件（分不清是靶仓测试写的还是同时段别的进程写的）⇒ 本机 TEMP 不在拆除阶段的视野里，算未清") }
                }
            } else { $unknown.Add('裁判强度报告里没有 MUT 机器读数行 —— 读数缺失，别引用它的分') }
        }
    }
    $st2 = if ($exitCode -eq 0) { 'complete' } elseif ($exitCode -eq 3) { 'partial/INCONCLUSIVE' } else { 'failed' }
    $note = if ($phaseFail) { "停在 $phaseFail" } elseif ($dNote) { "全门通过；$dNote" } else { '全门通过' }
    $cov.Add([pscustomobject]@{ phase = $ph.id; status = $st2; note = $note })
    if ($exitCode -ne 0) { $failAt = $phaseFail; break }
}
if (-not $started) { Write-Host "[wf] -FromPhase $FromPhase 不在本 profile 的阶段里"; exit 2 }

# 未核项：工具判不了的三类，永远显式带进 coverage
foreach ($d in @('daemon/watcher 进程', 'crontab 与计划任务', '用户级环境变量与 shell profile', '常驻端口与后台任务', '跨仓写入（只扫了目标仓一个目录）')) { $deferred.Add($d) }
if ($exitCode -ne 0) { $outcome = $(if ($exitCode -eq 3) { 'partial/INCONCLUSIVE' } else { 'failed' }) }

if (-not $DryRun) {
    $eng = @()
    foreach ($k in $tools.Keys) { if (Test-Path -LiteralPath $tools[$k]) { $eng += [pscustomobject]@{ tool = $k; path = $tools[$k]; sha256 = (Sha256Of $tools[$k]) } } }
    $mani = [pscustomobject]@{ schema = $mf.schema; runId = $runId; projectId = $projectId; repo = $repo; profile = $Profile; fromPhase = $FromPhase; confirmed = @($Confirm); inputs = [pscustomobject]@{ testCmd = $TestCmd; kitDir = $kit; mutationTargets = $mutT; maxMutants = $mutN; leaseTTLHours = $LeaseTTLHours; owner = $Owner }; outcome = $outcome; failAt = $failAt; startedAt = (Get-Date -Format 's'); manifest = (Split-Path $Manifest -Leaf); engines = $eng; sealedFiles = @('run-manifest.json','gates.json','coverage.json'); projectionNotSealed = 'report.md' }
    $gatesDoc = [pscustomobject]@{ runId = $runId; entries = $gates.ToArray() }
    $covDoc = [pscustomobject]@{ runId = $runId; outcome = $outcome; phases = $cov.ToArray(); unknown = $unknown.ToArray(); notChecked = $deferred.ToArray(); rule = 'unknown 不等于已解决；partial/failed 禁止作全量断言' }
    $mani | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirOut "run-manifest.json") -Encoding UTF8
    $gatesDoc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirOut "gates.json") -Encoding UTF8
    $covDoc | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDirOut "coverage.json") -Encoding UTF8
    $rep = New-Object System.Collections.Generic.List[string]
    $rep.Add("# 工作流运行投影（人读；不入密封）")
    $rep.Add("")
    $rep.Add("- run " + $runId + " / 目标 " + $repo)
    $rep.Add("- 结论：**" + $outcome + "**" + $(if ($failAt) { "，停在 " + $failAt } else { "" }))
    $rep.Add("- 语义文档：run-manifest.json / gates.json / coverage.json；密封 seal.json")
    $rep.Add("")
    $rep.Add("| 阶段 | 状态 | 备注 |")
    $rep.Add("|---|---|---|")
    foreach ($c in @($cov.ToArray())) { $rep.Add("| " + $c.phase + " | " + $c.status + " | " + $c.note + " |") }
    if ($unknown.Count -gt 0) { $rep.Add(""); $rep.Add("## unknown（本轮没采到，不许当已解决）"); foreach ($u in @($unknown.ToArray())) { $rep.Add("- " + $u) } }
    $rep.Add(""); $rep.Add("## 本工具判不了、必须人工核的"); foreach ($d in $deferred) { $rep.Add("- " + $d) }
    $rep.ToArray() | Set-Content -LiteralPath (Join-Path $runDirOut "report.md") -Encoding UTF8
    $seal = New-Object System.Collections.Generic.List[object]
    foreach ($n in @('run-manifest.json','gates.json','coverage.json')) { $seal.Add([pscustomobject]@{ name = $n; sha256 = (Sha256Of (Join-Path $runDirOut $n)) }) }
    [pscustomobject]@{ runId = $runId; algorithm = 'SHA-256'; files = $seal.ToArray(); meaning = '只证明本地三份语义文档未被改动；不是签名、不是发布者身份、不证明运行时加载过哪个版本' } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDirOut "seal.json") -Encoding UTF8
    Write-Host ("[wf] 语义文档 + 密封 → " + $runDirOut)
    Write-Host ("[wf] 核对：powershell -File workflow/workflow-run.ps1 -VerifySeal -RunDir """ + $runDirOut + """")
}
if ($exitCode -ne 0) { Write-Host ("[wf] {0}：停在 {1}。补齐这一门的条件，或人工确认后加 -Confirm。" -f $outcome, $failAt); exit $exitCode }
Write-Host "[wf] complete：全部命中阶段过关。"
exit 0
