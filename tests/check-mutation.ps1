<#
.SYNOPSIS
  check-mutation.ps1 —— 检 mutation-probe.ps1：它给的得分必须真能分出强弱裁判
.DESCRIPTION
  一个只会报"得分 0.5"的仪器没有价值；它必须在一对**已知强弱**的测试集上排出序来。
  夹具（临时目录，跑完即删）：
    src/*.js        9 个可变异点（含一个谁都不测的函数）
    strong/*.test.js 逐条测边界与布尔分支   -> 期望得分高
    weak/*.test.js   只测一个远离边界的取值 -> 期望得分低
  四条断言：M1 强>弱（序，不是绝对值）、M2 强 >= 0.6、M3 弱 <= 0.4、
  M4 基线本来就红时探针必须**拒跑**（rc=2 且不报得分）、M5 零变异点时不许把 0 说成"裁判强"，
  另外单列一条安全不变量：探针跑完，用户仓的每个文件哈希必须**一字未变**。
  读数一律走 ASCII 的 `MUT score=...` 机器行，不依赖中文（本 harness 自己设过码页，
  中文断言在这个环境里会恒真 —— 见 check-recon 的同款注释）。
.EXAMPLE
  powershell -NoProfile -File tests/check-mutation.ps1
#>
param(
    [string]$Script = "",
    [switch]$KeepSandbox
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot
if (-not $Script) { $Script = Join-Path $root "scripts\mutation-probe.ps1" }
if (-not (Test-Path -LiteralPath $Script)) { Write-Host "找不到被测脚本: $Script"; exit 2 }
$Script = (Resolve-Path -LiteralPath $Script).Path

# 沙箱前缀必须与探针工作副本的前缀**区分开**：上一版叫 lrf-mut-chk-*，
# 于是 M6 用 -Filter "lrf-mut-*" 查残留时第一个就命中了自己 —— 拿仪器当被测物。
$sb = Join-Path ([System.IO.Path]::GetTempPath()) ("lrf-mutchk-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$repo = Join-Path $sb "repo"
$pass = 0; $bad = 0; $skip = 0
function Chk($name, $hit, $detail) {
    if ($hit) { Write-Host ("  [OK] {0,-30} {1}" -f $name, $detail); $script:pass++ }
    else { Write-Host ("  [X ] {0,-30} {1}" -f $name, $detail); $script:bad++ }
}
function Skp($name, $why) { Write-Host ("  [SKIP] {0,-28} {1}" -f $name, $why); $script:skip++ }

$sh = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
$shArgs = if ($env:OS -eq 'Windows_NT') { @('-NoProfile','-ExecutionPolicy','Bypass','-File') } else { @('-NoProfile','-File') }
function Probe($repoArg, $testCmd, $targets, $maxM, $outF) {
    if (-not $maxM) { $maxM = 40 }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $call = @($Script, '-Repo', $repoArg, '-TestCmd', $testCmd, '-Targets', $targets, '-MaxMutants', "$maxM", '-TimeoutSec', '60')
        if ($outF) { $call = $call + @('-OutFile', $outF) }
        $txt = & $sh ($shArgs + [string[]]$call) 2>&1 | Out-String
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $o = [pscustomobject]@{ rc = $rc; score = -1.0; killed = -1; total = -1; avail = -1; uncov = -1; miss = -1; txt = $txt }
    if ($txt -match 'MUT score=([0-9.]+) killed=(\d+) total=(\d+)') {
        $o.score = [double]$matches[1]; $o.killed = [int]$matches[2]; $o.total = [int]$matches[3]
    }
    if ($txt -match 'avail=(\d+) uncov=(\d+)') { $o.avail = [int]$matches[1]; $o.uncov = [int]$matches[2] }
    if ($txt -match 'missing-targets=(\d+)') { $o.miss = [int]$matches[1] }
    return $o
}

try {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { Skp '全部' '本机没有 node，夹具跑不起来（探针本身不受影响）'; throw "skip" }

    # ---------- 夹具 ----------
    New-Item -ItemType Directory -Force -Path (Join-Path $repo "src"), (Join-Path $repo "strong"), (Join-Path $repo "weak"), (Join-Path $repo "broken"), (Join-Path $repo "src-empty") | Out-Null
    # 9 个可变异点：>= true false / < / > !== / <= / === / >（never 没人测）
    # 头两行注释里**故意塞进变异符**：枚举阶段若不分词法，这些会变成假变异点、把得分压低
    [System.IO.File]::WriteAllText((Join-Path $repo "src\calc.js"), (@"
'use strict';
// 注释里的 0 分母 a >= 18、b !== 9、c === 7 都不该被注
/* 块注释里也有 > 和 < 与 true */
function adult(x) { if (x >= 18) { return true } return false }
function teen(x) { return x < 13 }
function pick(x) { if (x > 5 && x !== 9) { return 1 } return 2 }
function safe(x) { return x <= 100 }
function odd(x) { return x === 7 }
function never(x) { return x > 3 }
module.exports = { adult, teen, pick, safe, odd, never };
"@ -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $repo "src-empty\plain.js"), "module.exports = 42;`n", (New-Object System.Text.UTF8Encoding($false)))
    # 强：逐条打边界与布尔分支
    [System.IO.File]::WriteAllText((Join-Path $repo "strong\all.test.js"), (@"
const t = require('node:assert').strict, { test } = require('node:test');
const c = require('../src/calc.js');
test('adult 边界', () => { t.equal(c.adult(18), true); t.equal(c.adult(17), false); });
test('teen 边界', () => { t.equal(c.teen(13), false); t.equal(c.teen(12), true); });
test('pick 边界', () => { t.equal(c.pick(5), 2); t.equal(c.pick(6), 1); t.equal(c.pick(9), 2); });
test('safe 边界', () => { t.equal(c.safe(100), true); t.equal(c.safe(101), false); });
test('odd 相等', () => { t.equal(c.odd(7), true); t.equal(c.odd(8), false); });
"@ -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    # 弱：只测一个远离边界的取值
    [System.IO.File]::WriteAllText((Join-Path $repo "weak\one.test.js"), (@"
const t = require('node:assert').strict, { test } = require('node:test');
const c = require('../src/calc.js');
test('adult 只测 25', () => { t.equal(c.adult(25), true); });
"@ -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    # 基线就红：探针必须拒跑
    [System.IO.File]::WriteAllText((Join-Path $repo "broken\bad.test.js"), (@"
const t = require('node:assert').strict, { test } = require('node:test');
test('故意红', () => { t.equal(1, 2); });
"@ -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

    # 用户仓哈希快照（跑完要比对，证明确实只动副本）
    function Snap($dir) {
        $h = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force)) { $h[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
        return $h
    }
    $before = Snap $repo

    # TestCmd 必须给**文件路径**：`node --test <目录>` 在 Node 24 下是把目录当测试文件加载，
    # 基线直接红 —— 我第一版就栽在这儿，被探针的基线闸门正确地拒了。
    $strong = Probe $repo "node --test strong/all.test.js" "src"
    $weak = Probe $repo "node --test weak/one.test.js" "src"
    $after = Snap $repo

    Write-Host ("[mutation] 脚本 = {0}" -f $Script)
    Write-Host ("[mutation] 强集 rc={0} score={1} killed={2}/{3}" -f $strong.rc, $strong.score, $strong.killed, $strong.total)
    Write-Host ("[mutation] 弱集 rc={0} score={1} killed={2}/{3}" -f $weak.rc, $weak.score, $weak.killed, $weak.total)

    $same = ($before.Count -eq $after.Count)
    foreach ($k in $before.Keys) { if (-not $after.ContainsKey($k) -or $after[$k] -ne $before[$k]) { $same = $false } }
    Chk 'M0 用户仓一字未变' $same "$($before.Count) 个文件哈希全等"

    Chk 'M1 强>弱（序）' ($strong.score -gt $weak.score) ("强 $($strong.score) vs 弱 $($weak.score)")
    Chk 'M2 强集 >= 0.6' ($strong.score -ge 0.6) ("实得 $($strong.score)，killed $($strong.killed)/$($strong.total)")
    Chk 'M3 弱集 <= 0.4' ($weak.score -le 0.4 -and $weak.score -ge 0) ("实得 $($weak.score)，killed $($weak.killed)/$($weak.total)")
    Chk 'M3b 两集分母相同' ($strong.total -eq $weak.total -and $strong.total -eq 9) "变异点 $($strong.total)/$($weak.total)（夹具设计 9）"

    $broken = Probe $repo "node --test broken/bad.test.js" "src"
    Chk 'M4 基线红必须拒跑' ($broken.rc -eq 2 -and $broken.score -lt 0) ("rc=$($broken.rc) score=$($broken.score)；报告行=" + $(if ($broken.txt -match 'BASELINE=red') { 'BASELINE=red 在' } else { '缺 BASELINE=red' }))

    $zero = Probe $repo "node --test strong/all.test.js" "src-empty"
    Chk 'M5 零变异点不许当好消息' ($zero.total -eq 0 -and $zero.txt -match '不代表裁判强') ("total=$($zero.total) rc=$($zero.rc)")
    # M5b（2026-09-28 补）：上一版只断"报了警告"，**没断退出码** —— 于是探针量不到任何东西时
    # 照样 exit 0，工作流那边靠"报告文件不存在"才间接发现。警告要配得上非零的 rc。
    Chk 'M5b 量不到东西必须 rc=3' ($zero.rc -eq 3) "rc=$($zero.rc)（设计：0 候选 = 没量到，不是成功）"

    # M10：词法过滤的真覆盖。JS 注释旧版就跳，所以证明不了新逻辑；这里用 Python 夹具：
    #   装饰线 `==================` 含 9 个 `==`、docstring 那行含 `==` `>` `True` 3 个，
    #   真代码只有 `>=` `True` `False` 3 个。不过滤的话 avail 会报 15（且得分被压到 0.2）。
    $py = Get-Command py -ErrorAction SilentlyContinue
    if (-not $py) { Skp 'M10 装饰线/docstring 不算候选' '本机没有 py 启动器' }
    else {
        $pyrepo = Join-Path $sb "pyrepo"
        New-Item -ItemType Directory -Force -Path $pyrepo | Out-Null
        # 单引号 here-string：不插值，`"""` 原样落盘（上一版用双引号拼三引号，拼坏了 Python 文件，
        # 结果 baseline 直接红、探针拒跑，报出来的 -1 看着像"过滤没生效"，其实是夹具坏了）
        $calcSrc = @'
# -*- coding: utf-8 -*-
"""
说明
==================
这里写 a == b 与 x > y，还有 True
"""

def adult(x):
    if x >= 18:
        return True
    return False
'@
        $checkSrc = @'
import sys
from calc import adult
bad = 0
if adult(18) is not True:
    bad += 1
if adult(17) is not False:
    bad += 1
sys.exit(1 if bad else 0)
'@
        [System.IO.File]::WriteAllText((Join-Path $pyrepo "calc.py"), ($calcSrc -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $pyrepo "check.py"), ($checkSrc -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $p3 = Probe $pyrepo "py -3 -X utf8 check.py" "calc.py" 40
        Chk 'M10 非代码 token 不算候选点' ($p3.avail -eq 3) "avail=$($p3.avail)（真代码 3；不过滤会是 15）score=$($p3.score)"
        Chk 'M10b 全漏放的假低分不再出现' ($p3.score -eq 1) "得分 $($p3.score)（旧探针会把装饰线当漏放，压到 0.2）"
    }

    # M11：目标**不存在**（清单默认值曾经写死 src，靶仓没有 src ⇒ 整轮量出 0 候选还 exit 0）。
    #   要求：计入 missing-targets、rc=3、报告照样落盘并写明"没有量到强度"。三样缺一样就是假成功。
    $mOut = Join-Path $sb "m11-report.md"
    $mt = Probe $repo "node --test strong/all.test.js" "no-such-dir" 40 $mOut
    $mTxt = if (Test-Path -LiteralPath $mOut) { [System.IO.File]::ReadAllText($mOut, [System.Text.Encoding]::UTF8) } else { '' }
    Chk 'M11 目标不存在要计进 missing-targets' ($mt.miss -eq 1) "missing-targets=$($mt.miss) rc=$($mt.rc)"
    Chk 'M11b 且 rc 非零' ($mt.rc -eq 3) "rc=$($mt.rc)（设计：3 = 一个候选点都没采到）"
    Chk 'M11c 报告照样落盘并写明没量到' ((Test-Path -LiteralPath $mOut) -and ($mTxt -match '没有量到强度') -and ($mTxt -match 'no-such-dir')) "报告 $(if (Test-Path -LiteralPath $mOut) {'在'} else {'不在'})；缺目标名字写进正文=$($mTxt -match 'no-such-dir')"

    # M12：整仓默认（清单默认值已从 src 改成 .）必须真采到东西。用 ≥ 下界，不猜绝对计数。
    $dot = Probe $repo "node --test strong/all.test.js" "."
    Chk 'M12 整仓目标能采到候选点' ($dot.avail -ge 9 -and $dot.rc -eq 0 -and $dot.miss -eq 0) "avail=$($dot.avail)（夹具真码 9 个变异点起）rc=$($dot.rc) missing=$($dot.miss)"

    # 工作副本用完必须删（探针自己清干净）。不用 -Filter：Windows 的 8.3 短名会让
    # "lrf-mut-*" 匹配到意料之外的东西；直接按名字正则取探针工作副本（时间戳开头是数字）。
    $left = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cmatch '^lrf-mut-\d{8}-\d{6}-' })
    Chk 'M6 探针没留工作副本' ($left.Count -eq 0) "残留 $($left.Count) 个 lrf-mut-* 目录"

    # 覆盖面自曝（防「把抽样当全仓」）：机器行必须带 avail=/uncov=，且截断时 uncov 要对得上。
    # 这里只断 ASCII 计数，不断那行中文警告 —— 码页继承会让中文断言偏严不偏松，但按本仓规矩，
    # 判据一律优先用机器读数（见 check-recon 里的同款注释）。
    $full = Probe $repo "node --test strong/all.test.js" "src" 40
    Chk 'M7 覆盖计数自曝 avail/uncov' ($full.avail -eq 9 -and $full.uncov -eq 0) "avail=$($full.avail)（期望 9）uncov=$($full.uncov)（期望 0）"
    $cut = Probe $repo "node --test strong/all.test.js" "src" 3
    Chk 'M8 名额截断要报未覆盖数' ($cut.uncov -eq 6 -and $cut.total -le 3 -and $cut.avail -eq 9) ("名额 3：avail=$($cut.avail) uncov=$($cut.uncov)（期望 9/6），本轮判了 $($cut.total)")
    Chk 'M9 抽样分与全量分不同值' ($cut.score -ne $full.score -or $cut.total -ne $full.total) "截断跑 score=$($cut.score) 判了 $($cut.total)；全量跑 score=$($full.score) 判了 $($full.total)"
} catch {
    if ($_.Exception.Message -ne 'skip') { Write-Host ("  [X ] 测试自身异常: " + $_.Exception.Message); $bad++ }
} finally {
    if ($KeepSandbox) { Write-Host "[mutation] 沙箱留着：$sb" }
    elseif (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
}
Write-Host ""
if ($bad -gt 0) { Write-Host "[mutation] 失败 $bad 项 / 通过 $pass 项 / SKIP $skip"; exit 1 }
if ($pass -eq 0) { Write-Host "[mutation] 一项都没测成（SKIP $skip）—— 不算通过"; exit 1 }
Write-Host "[mutation] 全部通过（$pass 项，SKIP $skip）。"
exit 0
