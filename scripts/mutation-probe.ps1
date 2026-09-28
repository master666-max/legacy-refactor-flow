<#
.SYNOPSIS
  mutation-probe.ps1 —— 量"裁判有多强"：往代码里注入语义改动，看你的测试会不会红
.DESCRIPTION
  本 skill 的铁律一要求"先造裁判"，但"造了裁判"不等于"裁判抓得住改动"。
  本探针就是把这个差别变成一个数：对目标文件逐个施加**文本级语义变异**（比较符、边界、布尔），
  每注一个就跑一遍测试；测试红了 = 这个变异被裁判看见（killed），测试还绿 = 裁判看不见（survived）。
  survived 的清单才是重点：那是"你的重构改坏了也没人报警"的位置。

  安全线：全程在 %TEMP% 的副本里做，**一行业务代码都不会被真改**；跑完删副本。
  基线红就拒跑：测试本来就是红的，任何"变异被抓住"都是假信号。

  ★ 但"副本里做"只管得住**探针自己**的写。测试命令是靶仓自带的，它想往哪儿写就往哪儿写：
    真仓实测（2026-09-28, dsh-launcher）dsh_tests.py 每个用例 tempfile.mkdtemp 不删，
    探针逐变异体重跑 19 遍 ⇒ 本机 TEMP 多了一百多个空目录。所以本件量 baseline 前后 TEMP 的
    **新增条目**并报成 `temp-new=N`（探针自己的 lrf-* 副本不计入）。N>0 不是失败，是代价：
    拆除阶段的台账看不见本机 TEMP，这些件得人工清或让靶仓测试自己回收。

  退出码：0 = 量到了（哪怕得分很低）；2 = 基线红/超时，拒跑；3 = **一个候选点都没采到**
  （目标不存在或指错地方）——报告仍会写，但这个 0 不是"裁判强"，不许上游当成功。

  为什么只内置兜底、不去驱动 Stryker/mutmut：那些工具要各自的语言配置与构建链，
  代跑半套比不跑更坏（配置错了会给出一个看似合理的得分）。装了它们请按报告末尾的命令自己跑，
  再把得分并进来。本探针给的是**下限证据**，不是充分性证明。
.EXAMPLE
  ./mutation-probe.ps1 -Repo D:\my\legacy -TestCmd "node --test" -Targets "src"
  ./mutation-probe.ps1 -Repo D:\my\legacy -TestCmd "py -m pytest -q" -MaxMutants 60 -OutFile mutation-report.md
#>
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$TestCmd,
    [string[]]$Targets = @('.'),
    [int]$MaxMutants = 40,
    [int]$TimeoutSec = 90,
    [string]$OutFile = "",
    [switch]$KeepWork
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not (Test-Path -LiteralPath $Repo)) { throw "路径不存在: $Repo" }
$root = (Resolve-Path -LiteralPath $Repo).Path
$isWin = ($env:OS -eq 'Windows_NT')
$exts = @('.js', '.mjs', '.cjs', '.ts', '.py', '.java', '.cs', '.go', '.rb', '.php', '.rs')
$testRe = '((^|[\\/_.-])(tests?|specs?|__tests__)([\\/_.-]|$))|_test\.|\.test\.|\.spec\.'
$noise = @('node_modules', '.git', 'dist', 'build', 'target', 'vendor', 'out', 'bin', 'obj', '__pycache__', '.venv', 'venv', '.next', '.nuxt', 'coverage', '.tox')

# 变异映射：长式在前，否则 `>=` 会被 `>` 的规则吃掉一半。
# 必须走 switch -casesensitive —— [ordered]@{} 与 @{} 的键都**大小写不敏感**，
# 同时放 'True' 和 'true'（Python 与 JS 两种写法）会当重复键报错（实测踩过）。
function Get-Mutant([string]$tok) {
    switch -casesensitive ($tok) {
        '>='    { return '>' }
        '<='    { return '<' }
        '==='   { return '!==' }
        '!=='   { return '===' }
        '=='    { return '!=' }
        '!='    { return '==' }
        '>'     { return '>=' }
        '<'     { return '<=' }
        'True'  { return 'False' }
        'False' { return 'True' }
        'true'  { return 'false' }
        'false' { return 'true' }
        default { return $null }
    }
}
$pat = '(>=' + '|' + '<=' + '|' + '===' + '|' + '!==' + '|' + '==' + '|' + '!=' + '|' + '>' + '|' + '<' + '|' + '\bTrue\b' + '|' + '\bFalse\b' + '|' + '\btrue\b' + '|' + '\bfalse\b' + ')'

function Test-Noise([string]$p) {
    foreach ($n in $noise) { if ($p -match ('[\\/]' + [regex]::Escape($n) + '[\\/]')) { return $true } }
    return $false
}

# 逐行分型：装饰线（`====` 这类 RST 下划线 / 分隔条）、注释、docstring 区、代码。
# 为什么要这个：真仓实测过一轮，`======================` 一行就贡献 7 个"漏放"，
# 把得分从 0.43 压到 0.30 —— 变异名额被等号线吃掉近一半，分数还被系统性压低。
# 这是**启发式**（不是词法器）：字符串字面量里的 token 仍可能被误跳/误采。
function Get-LineTags([string[]]$lines) {
    $tags = @()
    $inside = $false
    foreach ($ln in $lines) {
        $trips = ([regex]::Matches($ln, '"""')).Count + ([regex]::Matches($ln, "'''")).Count
        $t = 'code'
        if ($ln.Trim().Length -gt 0 -and $ln -match '^[\s=\-\*_\#~]+$') { $t = 'banner' }
        elseif ($ln -match '^\s*(#|%|//|/\*|\*)') { $t = 'comment' }
        elseif ($inside) { $t = 'docstring' }
        elseif ($trips -gt 0) { $t = 'docstring' }
        $tags += $t
        if (($trips % 2) -eq 1) { $inside = -not $inside }
    }
    return $tags
}

# ---------- 1. 副本 ----------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("lrf-mut-" + $stamp + "-" + (Get-Random -Maximum 9999))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$src = $root
$copied = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-Noise $_.FullName) -and $_.FullName -notmatch '[\\/]\.git[\\/]' })
foreach ($f in $copied) {
    $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/')
    $dst = Join-Path $work $rel
    $d = Split-Path -Parent $dst
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
}
Write-Host "[mut] 副本 $work（源 $($copied.Count) 文件；本轮只动副本）"

function Run-Tests([string]$dir) {
    # 载荷走文件：命令行里的中文与引号是编码雷区，把测试命令写成脚本再调。
    # 退出码由脚本自己 echo 进 _probe-rc.txt —— Start-Process -PassThru 不带 -Wait 时
    # $p.ExitCode 是 null，而 `$null -ne 0` 成立，会把**每一个**基线误判成红（实测踩过）。
    $res = @{ rc = -1; timedOut = $false; ok = $false }
    $rcFile = Join-Path $dir "_probe-rc.txt"
    $outFile = Join-Path $dir "_probe-out.txt"
    $errFile = Join-Path $dir "_probe-err.txt"
    if (Test-Path -LiteralPath $rcFile) { Remove-Item -LiteralPath $rcFile -Force }
    if ($isWin) {
        # 逐行 += 拼，别写 @('a', 'b' + $x)：PowerShell 里**逗号优先级高于 +**，
        # 那样会被解析成"先建数组再把 $x 当一个元素追加"，脚本被写成碎行（实测踩过，
        # 症状是测试明明跑绿了却拿不到退出码）。
        $runner = Join-Path $dir "_probe-run.cmd"
        $lines = @()
        $lines += '@echo off'
        $lines += ('call ' + $TestCmd)
        # 重定向必须写在 echo **前面**：`echo %ERRORLEVEL%> f` 会落成空文件
        # （cmd 把 `%ERRORLEVEL%>` 当变量名的一部分，不展开）—— 对照实测过：
        #   echo %ERRORLEVEL%> f  → 空   |   > f echo %ERRORLEVEL%  → 正确写出退出码
        $lines += ('> "' + $rcFile + '" echo %ERRORLEVEL%')
        $lines | Set-Content -LiteralPath $runner -Encoding ASCII
        $p = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', "`"$runner`"" -WorkingDirectory $dir -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } else {
        $runner = Join-Path $dir "_probe-run.sh"
        $lines = @()
        $lines += '#!/bin/sh'
        $lines += $TestCmd
        $lines += ('echo $? > "' + $rcFile + '"')
        $lines | Set-Content -LiteralPath $runner -Encoding ASCII
        $p = Start-Process -FilePath '/bin/sh' -ArgumentList $runner -WorkingDirectory $dir -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        try { $p.WaitForExit() } catch {}
        $res.timedOut = $true
        return $res
    }
    if (-not (Test-Path -LiteralPath $rcFile)) { return $res }     # 没写出退出码 = 没跑成，按红处理并如实报
    $raw = (Get-Content -LiteralPath $rcFile -Raw -ErrorAction SilentlyContinue)
    $code = 0
    if (-not [int]::TryParse((($raw -replace '\s', '')), [ref]$code)) { $res.timedOut = $true; return $res }
    $res.rc = $code; $res.ok = $true
    return $res
}

# ---------- 2. 基线（红就拒跑） ----------
# 顺手量"跑裁判的代价"：靶仓自带的测试可能往机器上写件，而探针会把这条测试命令**重跑 N+1 遍**。
# 真仓实测（2026-09-28, dsh-launcher）：dsh_tests.py 每个用例 tempfile.mkdtemp 不删，
# 本轮逐变异体重跑 ⇒ TEMP 里新增 167 个空目录，而拆除阶段对本机 TEMP 一无所知。
function Temp-Snap {
    $t = [System.IO.Path]::GetTempPath()
    try { @([System.IO.Directory]::GetFileSystemEntries($t)) } catch { @() }
}
$hashset = @{}
foreach ($e in (Temp-Snap)) { $hashset[$e] = $true }
$base = Run-Tests $work
if ($base.timedOut -or -not $base.ok -or $base.rc -ne 0) {
    $why = "红（rc=$($base.rc)）"
    if ($base.timedOut) { $why = "超时（$TimeoutSec 秒没跑完）" }
    elseif (-not $base.ok) { $why = "没跑出退出码（测试命令本身没执行成）" }
    Write-Host "[mut] BASELINE=red"
    Write-Host "[mut] 测试基线本来就不是绿的：$why —— 这时候量出来的得分全是假信号，拒跑。先把 -TestCmd 跑绿。"
    if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force }
    exit 2
}
Write-Host "[mut] BASELINE=green"

# ---------- 3. 枚举变异点（两阶段：先数清全仓候选，再取前 MaxMutants）----------
# 为什么要先数：只看"本轮 30 个"会把抽样当全仓 —— 实测在 dsh-launcher 上，
# 整仓那一跑 30 个名额全花在前三个文件上，最大的两个模块一个没碰到，报出来的 0.000 是抽样截断，不是全仓结论。
$allRows = New-Object System.Collections.Generic.List[object]
$avail = [ordered]@{}
$samp  = [ordered]@{}
$missing = New-Object System.Collections.Generic.List[string]
$scanCap = 5000
$scanTrunc = $false
foreach ($t in $Targets) {
    $tp = if ([System.IO.Path]::IsPathRooted($t)) { $t } else { Join-Path $work $t }
    if (-not (Test-Path -LiteralPath $tp)) {
        # 目标不存在是**配置错**，不是"这仓没有可变异的地方"。静默跳过的后果：整轮量出 0 候选，
        # 而 rc 照样 0、门照样过 —— 2026-09-28 在 dsh-launcher 上实发（清单默认目标 src 在该仓不存在）。
        $missing.Add($t)
        Write-Host ("[mut] ★ 目标不存在，已计入 targets_missing：$t")
        continue
    }
    $files = if ((Get-Item -LiteralPath $tp).PSIsContainer) {
        @(Get-ChildItem -LiteralPath $tp -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $exts -contains $_.Extension.ToLower() -and -not ($_.FullName -match $testRe) } |
            Sort-Object FullName)
    } else { @((Get-Item -LiteralPath $tp)) }
    foreach ($f in $files) {
        $relF = $f.FullName.Substring($work.Length).TrimStart('\', '/')
        $lines = @([System.IO.File]::ReadAllLines($f.FullName))
        $tags = @(Get-LineTags $lines)
        $cnt = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -ge $tags.Count -or $tags[$i] -ne 'code') { continue }   # 装饰线/注释/docstring 一律不注
            foreach ($m in [regex]::Matches($lines[$i], $pat)) {
                $to = Get-Mutant $m.Value
                if (-not $to) { continue }
                $cnt++
                if ($allRows.Count -lt $scanCap) {
                    $allRows.Add([pscustomobject]@{ File = $f.FullName; Rel = $relF; Line = $i; Tok = $m.Value; To = $to; At = $m.Index })
                } else { $scanTrunc = $true }
            }
        }
        if (-not $avail.Contains($relF)) { $avail[$relF] = 0; $samp[$relF] = 0 }
        $avail[$relF] += $cnt
        if ($scanTrunc) { break }
    }
    if ($scanTrunc) { break }
}
$mutants = @()
if ($allRows.Count -gt 0) {
    $take = $MaxMutants
    if ($take -gt $allRows.Count) { $take = $allRows.Count }
    $mutants = @($allRows.GetRange(0, $take))
}
foreach ($mu in $mutants) { if ($samp.Contains($mu.Rel)) { $samp[$mu.Rel] += 1 } }
$totalAvail = 0
foreach ($k in $avail.Keys) { $totalAvail += $avail[$k] }
$zeroFiles = @($avail.Keys | Where-Object { $samp[$_] -eq 0 -and $avail[$_] -gt 0 })
$missedPts = $totalAvail - $mutants.Count
Write-Host ("[mut] 候选点合计 $totalAvail 个，本轮取 $($mutants.Count) 个（上限 $MaxMutants，按文件序→行序→列序截断）")
if ($zeroFiles.Count -gt 0 -or $missedPts -gt 0) {
    Write-Host ("[mut] ★ 这是**抽样**不是全仓：$($zeroFiles.Count) 个文件一个没采到，还有 $missedPts 个候选点没进本轮。得分只代表本轮采到的那些位置。")
    foreach ($z in ($zeroFiles | Select-Object -First 12)) { Write-Host ("        未采到: " + $z + "（候选 " + $avail[$z] + " 个）") }
}
if ($mutants.Count -eq 0) {
    # 以前这里直接 exit 0 并且**不写报告**：0 候选被当成"跑完了"，下游的门只能靠"报告文件不存在"间接发现。
    # 现在照常出报告（内容就是"没量到"），并在末尾按 rc=3 退出 —— 量不到东西不是成功。
    Write-Host "[mut] 一个可变异点都没有 —— 目标选错了（-Targets 给的是不是测试目录/不存在的目录？），这个 0 不代表裁判强。"
}

# ---------- 4. 逐个注入 ----------
$killed = 0; $undecided = 0; $survived = New-Object System.Collections.Generic.List[object]
$cache = @{}
$n = 0
foreach ($mu in $mutants) {
    $n++
    $fp = $mu.File
    if (-not $cache.ContainsKey($fp)) { $cache[$fp] = @([System.IO.File]::ReadAllLines($fp)) }
    $orig = $cache[$fp]
    $line = $orig[$mu.Line]
    $newLine = $line.Substring(0, $mu.At) + $mu.To + $line.Substring($mu.At + $mu.Tok.Length)
    $trial = @($orig.Clone()); $trial[$mu.Line] = $newLine
    [System.IO.File]::WriteAllLines($fp, $trial)
    # 改动自证：注完回读，确认真与基线不同。读 dsh-mutate.py 时被它一句注释点出来——
    # "锚点不匹配 → 变异体被静默跳过 = 这条修复失去守护"。写没落地就把这格当"漏放/抓住"判，
    # 量的是空气。没变就记无法判定并踢出分母。
    $back = @([System.IO.File]::ReadAllLines($fp))
    if (($back -join "`n") -eq ($orig -join "`n")) {
        $undecided++
        [System.IO.File]::WriteAllLines($fp, $orig)
        $rel0 = $fp.Substring($work.Length).TrimStart('\', '/')
        Write-Host ("  [{0}/{1}] 无法判定  {2}:{3}  {4} -> {5}  <= 写入未生效（注完与原文逐行相同），这格踢出分母" -f $n, $mutants.Count, $rel0, ($mu.Line + 1), $mu.Tok, $mu.To)
        continue
    }
    $r = Run-Tests $work
    [System.IO.File]::WriteAllLines($fp, $orig)      # 立刻还原，下一个变异从同一起点出发
    $rel = $fp.Substring($work.Length).TrimStart('\', '/')
    if (-not $r.ok) {
        # 没拿到退出码 = 这一格根本没测成。不许混进"抓住"里虚高得分，也不许算"漏放"。
        $undecided++
        Write-Host ("  [{0}/{1}] 无法判定  {2}:{3}  {4} -> {5}  <= 测试命令没跑出退出码，这格踢出分母" -f $n, $mutants.Count, $rel, ($mu.Line + 1), $mu.Tok, $mu.To)
    } elseif ($r.timedOut -or $r.rc -ne 0) {
        $killed++
        Write-Host ("  [{0}/{1}] 抓住  {2}:{3}  {4} -> {5}" -f $n, $mutants.Count, $rel, ($mu.Line + 1), $mu.Tok, $mu.To)
    } else {
        $survived.Add([pscustomobject]@{ Rel = $rel; Line = ($mu.Line + 1); From = $mu.Tok; To = $mu.To })
        Write-Host ("  [{0}/{1}] 漏放  {2}:{3}  {4} -> {5}  <= 测试全绿，裁判没看见" -f $n, $mutants.Count, $rel, ($mu.Line + 1), $mu.Tok, $mu.To)
    }
}

# ---------- 5. 出报告 ----------
# 分母只算**真判了的**（抓住 + 漏放）；无法判定的那些踢出去，
# 否则一次跑挂会把得分压低、一次超时会被算成"抓住"把得分抬高。
$evaluated = $killed + $survived.Count
$score = 0
if ($evaluated -gt 0) { $score = [math]::Round($killed / $evaluated, 3) }

# 跑裁判的代价：只数**新增**且**不是仪器自己的**件（lrf-* 前缀是探针工作副本与自检沙箱，
# 把它们算进去就等于拿仪器当被测物 —— 每次都自己填这个计数）。
$probeOwn = 0
$newNames = New-Object System.Collections.Generic.List[string]
foreach ($e in (Temp-Snap)) {
    if ($hashset.ContainsKey($e)) { continue }
    $nm = [System.IO.Path]::GetFileName($e)
    if ($nm -like 'lrf-*') { $probeOwn++; continue }
    $newNames.Add($nm)
}
$tempNew = $newNames.Count
if ($tempNew -gt 0) {
    Write-Host ("[mut] COST temp-new=$tempNew（跑测试命令在 TEMP 新留下的非探针件；已排除探针自己的 $probeOwn 个）")
    foreach ($s in @($newNames | Select-Object -First 5)) { Write-Host ("        + " + $s) }
}

$L = New-Object System.Collections.Generic.List[string]
$L.Add("# 裁判强度探针报告")
$L.Add("")
$L.Add("- 生成时间：" + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
$L.Add("- 目标仓：``$root``")
$L.Add("- 测试命令：``$TestCmd``")
$L.Add("- **跑裁判的代价**：本轮在 TEMP 新留下 ``$tempNew`` 个**非探针产物**（是靶仓自带测试自己写的）⇒ 拆除阶段看不见本机 TEMP，这些得人工清或让靶仓测试自己回收")
$L.Add("- **变异来源：内置文本级兜底**（未驱动 Stryker/mutmut/cargo-mutants）")
$L.Add("- 变异点 $($mutants.Count) 个（判了 $evaluated 个）：抓住 $killed，漏放 $($survived.Count)，无法判定 $undecided —— **得分 $score**")
$L.Add("- 候选点合计 $totalAvail 个 / $($avail.Count) 个文件；本轮只取 $($mutants.Count) 个，剩余 $missedPts 个未进本轮")
if ($scanTrunc) { $L.Add("- ⚠ 扫描在 $scanCap 个候选点处截断，`候选点合计` 是**下界**") }
$L.Add("- 工作副本：``$work``" + $(if ($KeepWork) { "（保留）" } else { "（已删）" }))
$L.Add("")
$L.Add("## 1. 漏放清单（这才是本报告的用途）")
$L.Add("")
$L.Add("下面每一行都是一个**真实存在的语义改动，而你的测试全绿**。重构时改到这些位置，没人会报警。")
$L.Add("")
if ($survived.Count -gt 0) {
    $L.Add("| 位置 | 原 | 改成 |")
    $L.Add("|---|---|---|")
    foreach ($s in $survived) { $L.Add("| ``$($s.Rel):$($s.Line)`` | ``$($s.From)`` | ``$($s.To)`` |") }
} else { $L.Add("（无漏放）") }
$L.Add("")
$L.Add("## 1b. 本轮覆盖面（防「把抽样当全仓」）")
$L.Add("")
$L.Add("| 文件 | 候选点 | 本轮采到 |")
$L.Add("|---|---|---|")
foreach ($k in $avail.Keys) { $L.Add("| ``$k`` | $($avail[$k]) | $($samp[$k]) |") }
$L.Add("")
if ($zeroFiles.Count -gt 0) {
    $L.Add("**有 $($zeroFiles.Count) 个文件一个点都没采到**（上表采到列为 0 的那些）⇒ 本得分不覆盖它们，别说成全仓得分。")
}
if ($totalAvail -eq 0) {
    $L.Add("")
    $L.Add("## 1c. 本轮**没有量到强度**（候选点 0）")
    $L.Add("")
    $L.Add("- 这不是""裁判强""，也不是""测试全绿所以安全""——这是**什么都没量到**。")
    if ($missing.Count -gt 0) {
        $L.Add("- 给的目标里有 $($missing.Count) 个在仓内不存在：``" + (($missing | ForEach-Object { $_ }) -join ' , ') + "``")
        $L.Add("- 修法：把 `-Targets` 换成该仓真实存在的代码目录或文件；清单默认值是 ``.``（整仓），别照搬别处的 ``src``。")
    } else {
        $L.Add("- 目标存在但一个符合形状的可变异点都没有：多半 `-Targets` 指到了测试目录或非代码件。")
    }
}
$L.Add("")
$L.Add("## 2. 这个数不能说明什么")
$L.Add("")
$L.Add("- **只是下限证据**：内置兜底只做比较符/边界/布尔三类，覆盖面比工具窄得多；得分高不等于裁判强。")
$L.Add("- **枚举阶段按启发式跳过了装饰线 / 注释 / 三引号 docstring**（真仓实测：一行 `====================` 能贡献 7 个假漏放，把得分从 0.43 压到 0.30）。")
$L.Add("  这是**启发式不是词法器**：写在字符串字面量里的 `==`、`True` 仍可能被误采或误跳 ⇒ 分数只能横向比自己，不能当绝对度量。")
$L.Add("- **等价变异体未剔除**：注进去的改动若恰好不改变行为，测试本来就不该红，这类会被误计成""漏放""。")
$L.Add("- **触达率未知**：变异点若落在根本没被任何测试执行的代码上，必然显示为漏放 —— 那说明的是覆盖，不是裁判。")
$L.Add("- 装了 Stryker / mutmut / cargo-mutants / PIT 的，请按其原生配置再跑一遍并把得分并进来：")
$L.Add("  ``npx stryker run`` ／ ``mutmut run`` + ``mutmut junitxml`` ／ ``cargo mutants``")
$L.Add("")
$machine = "[mut] MUT score=$score killed=$killed total=$evaluated probed=$($mutants.Count) avail=$totalAvail uncov=$missedPts zero-files=$($zeroFiles.Count) undecided=$undecided missing-targets=$($missing.Count) temp-new=$tempNew baseline=green source=builtin-textual"
$L.Add("## 3. 机器读数")
$L.Add("")
$L.Add('```')
$L.Add($machine.TrimStart('[').TrimStart())
$L.Add('```')
$text = ($L -join [Environment]::NewLine)
if ($OutFile) {
    $target = $OutFile
    if (-not [System.IO.Path]::IsPathRooted($OutFile)) { $target = Join-Path (Get-Location).Path $OutFile }
    [System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[mut] 报告已写入 $target"
}
if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force }
Write-Host "[mut] 概要：得分 $score（抓住 $killed / 判了 $evaluated，漏放 $($survived.Count)，无法判定 $undecided，共探 $($mutants.Count)）"
Write-Host $machine
# rc=3 = 一个候选点都没采到（目标给错/不存在）：报告照写，但**不许当成功**。
# 为什么不 exit 0：0 候选时的"绿"会被上游当"强度量过了"，实测就这么骗过了一道门。
if ($totalAvail -eq 0) { Write-Host "[mut] 结论：本轮量不到强度（候选点 0）——按失败处理，别把 0 当安全。"; exit 3 }
exit 0
