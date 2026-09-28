<#
.SYNOPSIS
  check-workflow.ps1 —— 检工作流执行器：门会不会停、密封会不会破、产物在不在被检仓之外
.DESCRIPTION
  六条断言里最要紧的是 W4：**改一个字节 gates.json，-VerifySeal 必须报失败**。
  密封若验不出篡改，前面所有门记录都可以被事后改写，整套契约就只是装饰。
  W6 是反面配套：report.md 是人读投影，**故意不入密封**，改它不该让核对失败。
  其余：无人工确认必须停在 partial（W1）、全确认才 complete（W2）、
  缺 SCOPE.md 必须停在 A 阶段（W5）、run 产物不得落进被检仓（W0）。
  需要本机有 node 与 py 之外的东西都不需要；跑完删沙箱与 run 目录。
.EXAMPLE
  powershell -NoProfile -File tests/check-workflow.ps1
#>
param([switch]$KeepSandbox)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$skillRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $skillRoot "workflow\workflow-run.ps1"
if (-not (Test-Path -LiteralPath $runner)) { Write-Host "找不到执行器: $runner"; exit 2 }

$sb = Join-Path ([System.IO.Path]::GetTempPath()) ("lrf-wfchk-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$repo = Join-Path $sb "repo"
$kitName = '_refactor-kit'
$madeRuns = @()
$pass = 0; $bad = 0
# run 产物落在被检仓之外（~/.legacy-refactor-flow/runs/<projectId>/<runId>/），
# 所以收尾要能把自己造的 run 找回来。靠正则抓 stdout 不稳（有一次就没抓到），
# 改成「开工前存一份快照，收尾删快照之外、且 manifest 指向本沙箱的那些」——
# 判据是 run-manifest.json 的 repo 字段，绝不按目录名或时间猜，免得误删用户以前攒的证据。
$runsRoot = Join-Path $env:USERPROFILE ".legacy-refactor-flow\runs"
function AllRuns {
    if (-not (Test-Path -LiteralPath $runsRoot)) { return @() }
    $r = @()
    foreach ($pj in @(Get-ChildItem -LiteralPath $runsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        foreach ($rd in @(Get-ChildItem -LiteralPath $pj.FullName -Directory -Force -ErrorAction SilentlyContinue)) { $r += $rd.FullName }
    }
    return $r
}
$preRuns = @(AllRuns)
function Chk($n, $hit, $d) { if ($hit) { Write-Host ("  [OK] {0,-34} {1}" -f $n, $d); $script:pass++ } else { Write-Host ("  [X ] {0,-34} {1}" -f $n, $d); $script:bad++ } }
function W([string]$rel, [string]$txt) {
    $p = Join-Path $repo $rel
    $d = Split-Path -Parent $p
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($p, ($txt -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}
function Run([string[]]$argv) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $sh (@($shArgs + [string[]]@($runner) + $argv)) 2>&1 | Out-String; $rc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    # 每次跑都可能新建 run 目录，统一在这里登记，收尾才删得干净（且只删自己造的）
    $m = [regex]::Match($o, '\[wf\] run\s+(\S+)')
    if ($m.Success -and ($madeRuns -notcontains $m.Groups[1].Value)) { $madeRuns += $m.Groups[1].Value }
    return @{ rc = $rc; out = $o }
}

try {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host "  [SKIP] 需要 node"; exit 0 }
    $sh = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
    $shArgs = if ($env:OS -eq 'Windows_NT') { @('-NoProfile','-ExecutionPolicy','Bypass','-File') } else { @('-NoProfile','-File') }

    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    W '_refactor-kit/SCOPE.md' ("# SCOPE`r`n`r`n" + '[scope] IN_SCOPE=src/calc.js' + "`r`n`r`n## DoD（完成定义）`r`n- 重构后 38 用例仍绿且行为差异全部登记`r`n")
    W '_refactor-kit/TRIAGE.csv' "入口点,判定,观测窗口,触达画像`r`nstart-dsh.bat,LIVE,90d,桌面双击`r`nself_checks_tests.py,DEAD,90d,无引用`r`n"
    W 'src/calc.js' @'
'use strict';
// 注释里的 >= 与 === 不该算候选点
function adult(x) { if (x >= 18) { return true } return false }
function odd(x) { return x === 7 }
module.exports = { adult, odd };
'@
    W 'strong/all.test.js' @'
const t = require('node:assert').strict, { test } = require('node:test');
const c = require('../src/calc.js');
test('边界', () => { t.equal(c.adult(18), true); t.equal(c.adult(17), false); t.equal(c.odd(7), true); t.equal(c.odd(8), false); });
'@
    $g = Get-Command git -ErrorAction SilentlyContinue
    if ($g) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & git init -q $repo 2>&1 | Out-Null; & git -C $repo add -A 2>&1 | Out-Null; & git -C $repo -c user.email=t@t -c user.name=t commit -q -m seed 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
    }

    $base = @('-RepoPath', $repo, '-TestCmd', 'node --test strong/all.test.js', '-MaxMutants', '12')
    Write-Host "[wfchk] 执行器 = $runner"

    # W1 无人工确认 ⇒ 必须停在 partial，且退出码非零
    $r1 = Run ($base)
    Chk 'W1 人工门未确认不得 complete' ($r1.rc -eq 3 -and $r1.out -match 'INCONCLUSIVE') "rc=$($r1.rc)"
    $mRun = [regex]::Match($r1.out, '\[wf\] run\s+(\S+)')
    $runDir = $mRun.Groups[1].Value
    if ($runDir) { $madeRuns += $runDir }
    if (-not $runDir -or -not (Test-Path -LiteralPath $runDir)) { Write-Host "  [X ] 拿不到 run 目录，后续断言无从做起"; throw "no rundir" }
    Write-Host "        run = $runDir"

    # W2 全确认 ⇒ complete
    # 注意 -Confirm 是数组参数：重复给 `-Confirm A -Confirm C` 会被 PowerShell 拒收
    # （ParameterAlreadyBound），必须写成逗号列表
    $r2 = Run ($base + @('-Confirm', 'A,B,C,D,E,T'))
    $m2 = [regex]::Match($r2.out, '\[wf\] run\s+(\S+)')
    $runDir = $m2.Groups[1].Value
    if ($runDir -and ($madeRuns -notcontains $runDir)) { $madeRuns += $runDir }
    Chk 'W2 全确认应 complete 且 rc=0' ($r2.rc -eq 0 -and $r2.out -match 'complete') "rc=$($r2.rc)"
    if ($r2.rc -ne 0) {
        Write-Host "  ── W2 未跑通，主输出最后 14 行（停在哪个门，得看得见）──"
        (($r2.out -split "`r?`n") | Where-Object { "$_".Trim() -ne '' } | Select-Object -Last 14) | ForEach-Object { Write-Host ("    " + $_) }
    }
    $have = @('run-manifest.json', 'gates.json', 'coverage.json', 'report.md', 'seal.json')
    $miss = @($have | Where-Object { -not (Test-Path -LiteralPath (Join-Path $runDir $_)) })
    Chk 'W2b 五份产物齐全' ($miss.Count -eq 0) "缺: $(if($miss.Count){$miss -join ','}{'无'})"

    # W0 run 产物不得落进被检仓
    $leak = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $have -contains $_.Name })
    $leakTxt = '无'
    if ($leak.Count -gt 0) { $leakTxt = ($leak | ForEach-Object { $_.Name }) -join ',' }
    Chk 'W0 产物在被检仓之外' ($leak.Count -eq 0) "仓内泄漏: $leakTxt"

    # W0b ★ 子进程 CWD 必须是目标仓。这条专抓"相对 -OutFile 落到技能仓"：
    #     真踩过一次 —— recon 步骤 rc=1 且什么也没写，因为 CWD 是技能仓、父目录不存在。
    $polluted = @()
    foreach ($pp in @((Join-Path $skillRoot $kitName), (Join-Path $skillRoot ($kitName + '\recon-report.md')))) {
        if (Test-Path -LiteralPath $pp) { $polluted += $pp }
    }
    Chk 'W0b 技能仓自己不接收产物' ($polluted.Count -eq 0) ("污染: " + $(if ($polluted.Count) { $polluted -join ',' } else { '无' }))

    # W0d ★ 跑完一轮，被检仓的 git status 必须还是干净的。
    #     这条是"门被自己的产物挡死"的直接反向控制：recon 报告若落进 kitDir，
    #     -Sweep 就报 [?] git status 有变更 ⇒ 一个正常有未提交改动的仓永远过不了 T 阶段。
    $dirty = '（无 git，未测）'; $clean = $true
    if ($g) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $dirty = (& git -C $repo status --porcelain 2>&1 | Out-String).Trim() } finally { $ErrorActionPreference = $prev }
        $clean = ($dirty -eq '')
    }
    Chk 'W0d 跑完不许弄脏被检仓' $clean $(if ($clean) { 'git status 干净' } else { "脏: " + ($dirty -replace "`r?`n", ' | ') })

    # W0c 步骤必须留证据：gates.json 里 recon 那条得带输出尾部，否则失败了也没人知道为什么
    $gd = [System.IO.File]::ReadAllText((Join-Path $runDir 'gates.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $reconStep = @($gd.entries | Where-Object { $_.id -eq 'phase0-recon' })
    Chk 'W0c 工具步骤带输出证据' ($reconStep.Count -eq 1 -and "$($reconStep[0].detail)".Length -gt 0) `
        ("条目 $($reconStep.Count) 个，detail 长度 $("$($reconStep[0].detail)".Length)")

    # W8 轻量闸门（profile=gate）：这条专抓"-FromPhase 写死 A ⇒ 不含 A 的 profile 开箱即 rc=2"，
    #     以及 dry-run 把 planned 当结论的误读。
    $gbase = @('-RepoPath', $repo, '-TestCmd', 'node --test strong/all.test.js', '-MaxMutants', '12', '-Profile', 'gate')
    $r8 = Run ($gbase + @('-Confirm', 'B,D,E,T'))
    Chk 'W8 gate 档从本档第一阶段跑完' ($r8.rc -eq 0 -and $r8.out -match 'complete') "rc=$($r8.rc)"
    $r8d = Run ($gbase + @('-DryRun'))
    Chk 'W8b dry-run 未确认仍不出 complete' ($r8d.rc -eq 3 -and $r8d.out -match 'planned') "rc=$($r8d.rc)"

    # W10：探针**量不到东西**时，整条链不许出 rc=0。
    #   实发形状（2026-09-28 真仓 dsh-launcher）：清单默认 mutationTargets=src，该仓没有 src，
    #   探针静默跳过不存在的目标 ⇒ 0 候选 + exit 0 + 不写报告，D 段差点被当成"强度量过了"。
    #   修法两处：探针 0 候选 ⇒ rc=3 且报告照写；执行器把"步骤非零"升格为阶段失败。
    $r10 = Run ($base + @('-Profile', 'gate', '-MutationTargets', 'no-such-dir', '-Confirm', 'B'))
    $run10 = [regex]::Match($r10.out, '\[wf\] run\s+(\S+)').Groups[1].Value
    $stepRc = -9; $stepVer = '查不到'
    if ($run10 -and (Test-Path -LiteralPath (Join-Path $run10 'gates.json'))) {
        try {
            $gj = Get-Content -LiteralPath (Join-Path $run10 'gates.json') -Raw | ConvertFrom-Json
            $e = @($gj.entries | Where-Object { $_.kind -eq 'step' -and $_.id -eq 'mutation-probe' })
            if ($e.Count -gt 0) { $stepRc = $e[0].rc; $stepVer = $e[0].verdict }
        } catch {}
    }
    Chk 'W10 量不到强度时整体判失败' ($r10.rc -eq 1 -and $r10.out -match '停在 D/') "rc=$($r10.rc) 停点=$(if ($r10.out -match '停在 (D/\S+)') {$matches[1]} else {'?'})"
    Chk 'W10b 探针步骤按 rc=3 记账' ($stepRc -eq 3 -and $stepVer -eq 'fail') "step rc=$($stepRc) verdict=$($stepVer)"
    Chk 'W10c 报告仍落盘（写明没量到）' ((Test-Path -LiteralPath (Join-Path $run10 'mutation-report.md')) -or ($r10.out -match '报告已写入')) "报告落盘标记=$($r10.out -match '报告已写入')"

    # W11：给"步骤非零 ⇒ 阶段判不过"这条规则单独配证人。
    #   W10 里 D-g3 先判了失败，所以那条新规则其实没被触到 —— 没有证人的强制规则就是在装饰。
    #   做法：拿真清单改合成一个阶段，**门设计成会过**、步骤设计成 rc=7，看整体还报不报"通过"。
    # ★ 读写都必须显式 UTF8：PS 5.1 的 Get-Content 默认按 ANSI(GBK) 解，清单里的中文会变乱码，
    #   ConvertFrom-Json 接着报"应为 : 或 }"——长得像清单坏了，其实是读法坏了。
    $mfRaw = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'workflow\legacy-refactor-flow.workflow.json'), [System.Text.Encoding]::UTF8)
    $mf = ConvertFrom-Json $mfRaw
    $mf.phases = @([pscustomobject]@{
        id = 'Z'; name = 'synthetic'; goal = 'witness the step-failure rule'
        steps = @([pscustomobject]@{ kind = 'cmd'; cmd = 'node -e "process.exit(7)"'; desc = 'step7' },
                  [pscustomobject]@{ kind = 'cmd'; cmd = 'node -e "process.exit(0)"'; desc = 'step0' })
        gates = @([pscustomobject]@{ id = 'Z-g1'; op = 'exists'; path = '{kitDir}/SCOPE.md'; desc = 'this gate passes' })
    })
    foreach ($pk in @($mf.profiles.PSObject.Properties.Name)) { $mf.profiles.$pk.phases = @('Z') }
    $zman = Join-Path $sb 'z-manifest.json'
    [System.IO.File]::WriteAllText($zman, (ConvertTo-Json -InputObject $mf -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $r11 = Run @('-RepoPath', $repo, '-TestCmd', 'node --test strong/all.test.js', '-Profile', 'full', '-Manifest', $zman)
    Chk 'W11 门全过但步骤非零：整体判失败' ($r11.rc -eq 1 -and $r11.out -match 'Z-g1\] 过' -and $r11.out -match 'rc=7') "rc=$($r11.rc) 门过=$($r11.out -match 'Z-g1\] 过') 步骤 rc=7 在册=$($r11.out -match 'rc=7')"
    Chk 'W11b 失败原因指到步骤而非门' ($r11.out -match '步骤非零' -and $r11.out -match '停在 D|step:step7') "停点写法=$(if ($r11.out -match '停在 ([^\s。]+)') {$matches[1]} else {'?'})"

    # W3 密封核对：原样应通过
    $r3 = Run @('-VerifySeal', '-RunDir', $runDir)
    Chk 'W3 原样密封核对通过' ($r3.rc -eq 0) "rc=$($r3.rc)"

    # W4 ★ 篡改 gates.json 必须被验出
    $gp = Join-Path $runDir 'gates.json'
    $orig = [System.IO.File]::ReadAllBytes($gp)
    [System.IO.File]::WriteAllText($gp, ([System.Text.Encoding]::UTF8.GetString($orig) + ' '), (New-Object System.Text.UTF8Encoding($false)))
    $r4 = Run @('-VerifySeal', '-RunDir', $runDir)
    Chk 'W4 篡改语义文档必须验破' ($r4.rc -eq 1 -and $r4.out -match '已被改动|gates.json') "rc=$($r4.rc)"
    [System.IO.File]::WriteAllBytes($gp, $orig)
    $r4b = Run @('-VerifySeal', '-RunDir', $runDir)
    Chk 'W4b 还原后重新通过' ($r4b.rc -eq 0) "rc=$($r4b.rc)"

    # W6 report.md 是投影，故意不入密封
    $rp = Join-Path $runDir 'report.md'
    Add-Content -LiteralPath $rp -Value "<!-- 事后加了注释 -->" -Encoding UTF8
    $r6 = Run @('-VerifySeal', '-RunDir', $runDir)
    Chk 'W6 改投影不影响密封（设计如此）' ($r6.rc -eq 0) "rc=$($r6.rc)"

    # W12 A-g4 不是装饰：把界指到"顶层函数 0 个"的件上 ⇒ 必须停在 A/A-g4。
    #     （真仓 2026-09-28 就是这么挑错件的：dsh-env.py 一行 def 都没有，裁判根本录不出来。）
    W 'src/no-func.py' "import os`r`nprint(os.getcwd())`r`n"
    W '_refactor-kit/SCOPE.md' ("# SCOPE`r`n`r`n" + '[scope] IN_SCOPE=src/no-func.py' + "`r`n`r`n## DoD（完成定义）`r`n- 同上`r`n")
    $r12 = Run ($base + @('-Confirm', 'A'))
    Chk 'W12 界挑了守不住的件要停在 A-g4' ($r12.rc -eq 1 -and $r12.out -match 'A-g4') "rc=$($r12.rc)"
    W '_refactor-kit/SCOPE.md' ("# SCOPE`r`n`r`n" + '[scope] IN_SCOPE=src/calc.js' + "`r`n`r`n## DoD（完成定义）`r`n- 重构后 38 用例仍绿且行为差异全部登记`r`n")

    # W13 跑裁判的代价必须落进 coverage 的 unknown：测试命令往本机 TEMP 写件时，
    #     D 段不许把"全门通过"念成"什么都没留下"。代价脚本放在被检仓**之外**，
    #     否则清单默认的 -Targets . 会把它当变异点扫。
    #     ★ 每次调用必须建**新名**目录：工作流在探针之前自己就跑过一遍测试命令，
    #       固定名的话探针开机时它已经在 ⇒ 报 temp-new=0（真话，但证不到东西）。
    $costTag = 'wfchk-cost-' + (Split-Path -Leaf $sb)
    $costTool = Join-Path $sb 'cost-tool\mkcost.js'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $costTool) | Out-Null
    [System.IO.File]::WriteAllText($costTool, ("const fs=require('fs'),os=require('os');fs.mkdirSync(os.tmpdir()+'/" + $costTag + "-'+process.pid+'-'+Date.now());process.exit(0);"), (New-Object System.Text.UTF8Encoding($false)))
    $b13 = @('-RepoPath', $repo, '-TestCmd', ("node --test strong/all.test.js && node " + $costTool), '-MaxMutants', '12')
    $r13 = Run ($b13 + @('-Confirm', 'A,B,C,D,E,T'))
    $run13 = [regex]::Match($r13.out, '\[wf\] run\s+(\S+)').Groups[1].Value
    $unk13 = ''
    if ($run13 -and (Test-Path -LiteralPath (Join-Path $run13 'coverage.json'))) {
        $c13 = [System.IO.File]::ReadAllText((Join-Path $run13 'coverage.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $unk13 = (@($c13.unknown) -join ' | ')
    }
    $costMade = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter ($costTag + '*') -ErrorAction SilentlyContinue)
    Chk 'W13 跑裁判的代价要记进 unknown' ($unk13 -match '跑裁判的代价' -and $costMade.Count -ge 1) ("rc=$($r13.rc) 代价目录 $($costMade.Count) 个；unknown 里$(if($unk13 -match '跑裁判的代价'){'有'}else{'没有'})代价条")

    # W5 缺 SCOPE.md ⇒ 停在 A 阶段，非零退出
    Remove-Item -LiteralPath (Join-Path $repo '_refactor-kit\SCOPE.md') -Force
    $r5 = Run ($base + @('-Confirm', 'A'))
    Chk 'W5 缺 SCOPE 必须停在 A 门' ($r5.rc -eq 1 -and $r5.out -match 'A-g1') "rc=$($r5.rc)"

    # coverage 语义：unknown 有值时不得声称全仓
    $cv = [System.IO.File]::ReadAllText((Join-Path $runDir 'coverage.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Chk 'W7 coverage 带未核清单' (@($cv.notChecked).Count -ge 3) "notChecked $($cv.notChecked.Count) 项；unknown $(@($cv.unknown).Count) 项"

    # W9 B-g4（自相矛盾门）不是恒真：拿清单里**实际发布的那条 pattern** 打两种形状
    $mfp = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'workflow\legacy-refactor-flow.workflow.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $bg4 = $null
    foreach ($ph in @($mfp.phases)) { foreach ($gt in @($ph.gates)) { if ($gt.id -eq 'B-g4') { $bg4 = $gt } } }
    $lying = "## 5. 测试基础设施现状`r`n[recon] TEST_INFRA=config configs=1 structural=0`r`n**配置文件名单与结构判据两路都没命中 —— 这才叫从零开始造裁判。**"
    $honestNone = "## 5. 测试基础设施现状`r`n[recon] TEST_INFRA=none configs=0 structural=0`r`n**配置文件名单与结构判据两路都没命中 —— 这才叫从零开始造裁判。**`r`n## 6. 入口点候选`r`n（名字白名单与结构判据两路都没命中 —— 入口点要从别处取。）"
    $fired = ($lying -match $bg4.pattern)
    $quiet = ($honestNone -match $bg4.pattern)
    Chk 'W9 矛盾门能开也能不开' ($fired -and (-not $quiet)) "说谎样本命中=$fired（应为 True）；诚实 none 样本命中=$quiet（应为 False）"
    # 且这条门本轮真的被评估过（不是只在字符串层面成立）
    $g4 = @($gd.entries | Where-Object { $_.id -eq 'B-g4' })
    Chk 'W9b 矛盾门本轮被评估' ($g4.Count -eq 1 -and $g4[0].verdict -eq 'pass') "条目 $($g4.Count) 个，verdict $(if($g4.Count){$g4[0].verdict}else{'-'})"
} catch {
    if ($_.Exception.Message -ne 'no rundir') { Write-Host ("  [X ] 测试自身异常: " + $_.Exception.Message); $bad++ }
} finally {
    # 只删本次跑出来的 run 目录（连空掉的 projectId / runs 父目录一起收），
    # 绝不动 ~/.legacy-refactor-flow 下用户以前攒的 run —— 那是别人的证据
    if (-not $KeepSandbox) {
        # 先按 manifest 认亲：只删「开工后新出现」且「目标在本次沙箱仓里」的 run
        $mine = @()
        foreach ($rd in @(AllRuns)) {
            if ($preRuns -contains $rd) { continue }
            $mani = Join-Path $rd 'run-manifest.json'
            if (Test-Path -LiteralPath $mani) {
                # 注意："$((…) | ConvertFrom-Json).repo" 这种写法在 PS 里不会取到成员，
                # 会把整个对象哈希表打印出来 ⇒ 判据恒不命中、run 全被"跳过"（实测踩过）
                $ob = [System.IO.File]::ReadAllText($mani, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $rv = [string]$ob.repo
                if (-not ($rv -like ($repo + '*'))) { Write-Host "[wfchk] ★ 跳过非本次的 run：$rd（目标 $rv）"; continue }
            }
            $mine += $rd
        }
        foreach ($rd in $madeRuns) { if (($mine -notcontains $rd) -and (Test-Path -LiteralPath $rd)) { $mine += $rd } }
        if (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
        # W13 造的代价目录在被检仓之外（本机 TEMP），沙箱删不到它 —— 本夹具自己写的，自己收
        foreach ($cd in @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'wfchk-cost-*' -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $cd.FullName -Recurse -Force
        }
        foreach ($rd in $mine) {
            if (-not (Test-Path -LiteralPath $rd)) { continue }
            Remove-Item -LiteralPath $rd -Recurse -Force
            $pp = Split-Path -Parent $rd
            if ((Test-Path -LiteralPath $pp) -and @(Get-ChildItem -LiteralPath $pp -Force).Count -eq 0) { Remove-Item -LiteralPath $pp -Force }
            $gp2 = Split-Path -Parent $pp
            if ((Test-Path -LiteralPath $gp2) -and @(Get-ChildItem -LiteralPath $gp2 -Force).Count -eq 0) { Remove-Item -LiteralPath $gp2 -Force }
        }
        $stray = @(AllRuns | Where-Object { $preRuns -notcontains $_ })
        if ($stray.Count -gt 0) { Write-Host ("[wfchk] ★ 收尾后仍有新 run 残留: " + ($stray -join ', ')) }
    } else { Write-Host "[wfchk] 沙箱与 run 保留：$sb" }
}
Write-Host ''
if ($bad -gt 0) { Write-Host "[wfchk] 失败 $bad 项 / 通过 $pass 项"; exit 1 }
Write-Host "[wfchk] 全部通过（$pass 项）。"
exit 0
