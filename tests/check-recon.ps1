<#
.SYNOPSIS
  check-recon.ps1 —— phase0-recon.ps1 的七条报告断言（v1.0 逐条踩空的地方）
.DESCRIPTION
  在 %TEMP% 造一个**已知形状**的沙箱仓，跑侦察脚本，然后拿"沙箱里本来有什么"当期望值
  去核对报告 —— 期望值全部写死在本文件里，不取自被测输出，否则判据就是恒真的。
  沙箱故意做成：根目录没有任何测试/构建配置，配置全在第一层子目录里（专打"只查根目录"
  那条），提交信息含中文（专打编码那条），并带 dist/ 与 build/ 噪声目录（专打目录表）。
  跑完即删。
.EXAMPLE
  powershell -NoProfile -File tests/check-recon.ps1
#>
param(
    [string]$Script = "",
    [switch]$KeepSandbox,
    [switch]$Verbose2
)
$ErrorActionPreference = "Stop"
# 「出厂控制台码页」必须从注册表取，不能取 [Console]::OutputEncoding 的现值：
# 本脚本与被测脚本都会设 UTF-8，而 SetConsoleOutputCP 作用于**整个控制台**而非单进程，
# 同一批测试第二次跑时读到的现值已经被上一次改成 65001 —— 拿它当期望值就是顺序依赖的恒真判据。
$asFoundCP = try { [Console]::OutputEncoding.CodePage } catch { 0 }
$oemCP = try {
    $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name OEMCP -ErrorAction Stop).OEMCP
    [int]$v
} catch { 0 }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $PSScriptRoot
if (-not $Script) { $Script = Join-Path $root "scripts\phase0-recon.ps1" }
if (-not (Test-Path -LiteralPath $Script)) { Write-Host "找不到被测脚本: $Script"; exit 2 }
$Script = (Resolve-Path -LiteralPath $Script).Path

# ---------- 写死的期望值（来自沙箱设计，不来自报告） ----------
$EXP_SUB_INI    = 'pkg-a/pytest.ini'      # 子项目里的测试配置，v1.0 的根目录探测扫不到
$EXP_SUB_TESTS  = 'pkg-a/tests'
$EXP_CN_COMMIT  = '侦察脚本自测夹具：中文提交信息编码核验'
$EXP_NOISE_DIRS = @('dist', 'build', 'node_modules', '.git')
$EXP_BIGFILE    = 'bigmod.py'

$sb = Join-Path ([System.IO.Path]::GetTempPath()) ("lrf-recon-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$repo = Join-Path $sb "repo"
$report = Join-Path $sb "report.md"

function W($rel, $text) {
    $p = Join-Path $repo $rel
    $d = Split-Path -Parent $p
    if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$pass = 0; $bad = 0; $skip = 0
# git 的警告与进度一律往 stderr 写；`core.autocrlf=true`（Git for Windows 默认档）下 `add` 必报
# CRLF 警告，会把 ErrorActionPreference=Stop 的 harness 当场掀翻。所有 git 调用统一走这层包装。
function G([string[]]$ga) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return (& git @ga 2>&1 | Out-String) } finally { $ErrorActionPreference = $prev }
}
function Chk($name, $hit, $detail) {
    if ($hit) { Write-Host ("  [OK] {0,-26} {1}" -f $name, $detail); $script:pass++ }
    else { Write-Host ("  [X ] {0,-26} {1}" -f $name, $detail); $script:bad++ }
}
function Skp($name, $detail) { Write-Host ("  [SKIP] {0,-24} {1}" -f $name, $detail); $script:skip++ }

try {
    # ---------- 沙箱 ----------
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    W 'README.md' "# fixture`r`n"
    W ('src' + [IO.Path]::DirectorySeparatorChar + 'main.py') "import bigmod`r`nprint(1)`r`n"
    # 体量榜要能出东西：一个明显大的文件
    $big = ""; for ($i = 0; $i -lt 400; $i++) { $big += "v$i = $i`r`n" }
    W ('src' + [IO.Path]::DirectorySeparatorChar + $EXP_BIGFILE) $big
    W ('src' + [IO.Path]::DirectorySeparatorChar + ('中文命名模块.py')) "z = 3`r`n"
    # 测试/构建配置**只放在一级子目录**，根目录一个都不给
    W ('pkg-a' + [IO.Path]::DirectorySeparatorChar + 'pytest.ini') "[pytest]`r`n"
    W ('pkg-a' + [IO.Path]::DirectorySeparatorChar + 'tests' + [IO.Path]::DirectorySeparatorChar + 'test_a.py') "def test_a():`r`n    assert True`r`n"
    W ('pkg-b' + [IO.Path]::DirectorySeparatorChar + 'package.json') "{`"name`": `"pkg-b`"}`r`n"
    # 噪声目录：必须不出现在一级目录表里
    W ('dist' + [IO.Path]::DirectorySeparatorChar + 'bundle.js') "console.log(1)`r`n"
    W ('build' + [IO.Path]::DirectorySeparatorChar + 'out.js') "console.log(2)`r`n"
    W ('node_modules' + [IO.Path]::DirectorySeparatorChar + 'left' + [IO.Path]::DirectorySeparatorChar + 'index.js') "module.exports=1`r`n"

    $gitExe = Get-Command git -ErrorAction SilentlyContinue
    $hasGit = $false
    if ($gitExe) {
        # 显式关掉 autocrlf：Git for Windows 默认 true 会在 add 时往 stderr 报 CRLF 警告，
        # 也会让"报告里那条路径是相对还是绝对"这类判据掺进换行符噪声。靶仓要与真仓声明这一处不同。
        $ac = @('-c','core.autocrlf=false')
        G (@('init','-q',$repo)) | Out-Null
        G ($ac + @('-C',$repo,'add','-A')) | Out-Null
        $msgFile = Join-Path $sb "commit-msg.txt"
        [System.IO.File]::WriteAllText($msgFile, $EXP_CN_COMMIT + "`n", (New-Object System.Text.UTF8Encoding($false)))
        G ($ac + @('-C',$repo,'-c','user.email=t@t','-c','user.name=t','commit','-q','-F',$msgFile)) | Out-Null
        if ($LASTEXITCODE -eq 0) { $hasGit = $true }
    }
    if (-not $hasGit) { Write-Host "  !! git 不可用：热力与提交信息两条断言只能 SKIP" }

    # ---------- 跑 ----------
    # 用一层 ASCII 壳把控制台码页钉回出厂值，再调被测脚本：
    # 这样"没设 OutputEncoding 的脚本"必须现出乱码原形，设了的才能过 R6/R7。
    $sh = if ($env:OS -eq 'Windows_NT') { 'powershell' } else { 'pwsh' }
    $reproCP = ($env:OS -eq 'Windows_NT') -and ($oemCP -ne 0) -and ($oemCP -ne 65001)
    Write-Host ("[recon] 机器 OEM 码页 = $oemCP（控制台现值 $asFoundCP）")
    $runner = $Script
    $wrapArgs = @('-RepoPath', $repo, '-OutFile', $report, '-TopN', '10')
    if ($reproCP) {
        $runner = Join-Path $sb "runner.ps1"
        $lines = @(
            '$ErrorActionPreference = "Continue"',
            "[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding($oemCP)",
            "& '$Script' -RepoPath '$repo' -OutFile '$report' -TopN 10",
            'exit $LASTEXITCODE'
        )
        [System.IO.File]::WriteAllText($runner, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        $wrapArgs = @()   # 参数已写死在壳里，别再重复传一遍
    } else {
        Write-Host ("  !! 取不到非 UTF-8 的出厂码页（OEM=$oemCP），构造不出「中文控制台默认 GBK」的条件 —— R6 只能记 SKIP")
    }
    $shArgs = if ($env:OS -eq 'Windows_NT') { @('-NoProfile','-ExecutionPolicy','Bypass','-File') } else { @('-NoProfile','-File') }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $sh ($shArgs + [string[]]@($runner) + [string[]]$wrapArgs) 2>&1 | Out-String }
    finally { $ErrorActionPreference = $prev }
    $rc = $LASTEXITCODE
    Write-Host ("[recon] 脚本 = {0}" -f $Script)
    if ($Verbose2) { Write-Host $out }
    Chk '退出码' ($rc -eq 0) "rc=$rc"
    if (-not (Test-Path -LiteralPath $report)) { Write-Host "  [X ] 报告没落盘"; exit 1 }

    $bytes = [System.IO.File]::ReadAllBytes($report)
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes) -replace '^﻿', ''

    # 分节
    function Sec($n) {
        $m = [regex]::Match($txt, "(?ms)^## $n\..*?(?=^## \d|\z)")
        if ($m.Success) { return $m.Value } else { return "" }
    }
    function Rows($s) { @($s -split "`r?`n" | Where-Object { $_ -match '^\|' } | Select-Object -Skip 2) }

    # 统计来源必须落在已知四个值里。识别不出来就判失败 —— 拿"读不懂"当 SKIP
    # 就是把 R1 那条最要害的断言静默放掉（第一版正是栽在这儿：正则没排掉 markdown 的 **）
    $srcStat = ([regex]::Match($txt, '统计来源：\*?\*?([^（*\n]*)')).Groups[1].Value.Trim()
    $srcKnown = ($srcStat -match '^(scc|tokei|cloc|内置兜底)$')
    Write-Host ("[recon] 报告里的统计来源 = {0}" -f $srcStat)
    Chk 'R0 统计来源可识别' $srcKnown "解析值 = '$srcStat'"

    # R1 语言名不得为空（只有走 scc 才测得到 Language→Name 那条修正）
    $lang = Rows (Sec 1)
    $emptyName = @($lang | Where-Object { $_ -match '^\|\s*\|' })
    if ($srcStat -eq 'scc') { Chk 'R1 语言名非空' ($emptyName.Count -eq 0 -and $lang.Count -gt 0) ("{0} 行，空名 {1} 行" -f $lang.Count, $emptyName.Count) }
    else { Skp 'R1 语言名非空' "统计来源是 $srcStat（兜底路径用扩展名当语言名，本就非空，测不到那条修正）" }

    # R2 体量表不得整表空
    $size = Rows (Sec 2)
    Chk 'R2 体量表有内容' ($size.Count -gt 0) ("{0} 行" -f $size.Count)
    Chk 'R2b 大文件在册'  (($size -join "`n") -match [regex]::Escape($EXP_BIGFILE)) "期望 $EXP_BIGFILE"

    # R3 热力表：不得混进 java 报错，且要有行
    $sec3 = Sec 3
    $pollute = [regex]::Matches($sec3, 'Invalid argument|Parse error|java\.lang\.', 'IgnoreCase').Count
    $churn = Rows $sec3
    if ($hasGit) {
        Chk 'R3 热力表无污染' ($pollute -eq 0) ("报错文本 {0} 处" -f $pollute)
        Chk 'R3b 热力表有行'  ($churn.Count -gt 0) ("{0} 行" -f $churn.Count)
    } else { Skp 'R3 热力表' '沙箱没建起 git 历史' }

    # R4 一级目录表不得混进噪声目录
    $dirs = @(Rows (Sec 7) | ForEach-Object { ($_ -split '\|')[1].Trim() })
    $leak = @($dirs | Where-Object { $EXP_NOISE_DIRS -contains $_ })
    $leakTxt = "无"; if ($leak.Count -gt 0) { $leakTxt = ($leak -join ',') }
    Chk 'R4 目录表无噪声' ($leak.Count -eq 0) ("泄漏: $leakTxt ｜表内: $($dirs -join ',')")

    # R5 测试设施：必须报出子项目里的配置，且不得说"从零开始"
    $sec5 = Sec 5
    Chk 'R5 检出子项目配置' ($sec5 -match [regex]::Escape($EXP_SUB_INI) -and $sec5 -match [regex]::Escape($EXP_SUB_TESTS)) ("期望含 $EXP_SUB_INI + $EXP_SUB_TESTS")
    # R5b 是**绊线**（断旧版那句假结论不再出现）；真正能证伪的是扁平仓的 R9——
    # 因为旧代码在这份夹具上恰好也不会撒谎（monorepo 扫描早就修过），断言必须是"点名学生"而不是"某词不出现"。
    Chk 'R5b 旧假结论措辞不再出现' ($sec5 -notmatch '未检测到任何测试/构建配置文件') "报告第 5 节：$($sec5 -replace '\r?\n',' ' )"

    # R6 中文提交信息必须逐字可见（打的是"脚本没设码页 → 子进程输出被 GBK 解坏"那条）
    if ($hasGit -and $reproCP) { Chk 'R6 中文提交信息' ($txt -match [regex]::Escape($EXP_CN_COMMIT)) "钉在 OEM 码页 $oemCP 下逐字找: $EXP_CN_COMMIT" }
    elseif (-not $hasGit) { Skp 'R6 中文提交信息' '沙箱没建起 git 历史' }
    else { Skp 'R6 中文提交信息' "取不到非 UTF-8 的出厂码页，构造不出该故障" }

    # ---------- 第二个夹具：扁平 CLI 仓（v1.3 在这两种形状上都说错话）----------
    # 形状：没有任何测试/构建配置文件，但根目录有个自定义命名的测试模块；
    #      入口模块的名字都不在白名单里，真正的用户入口是个 .bat。
    $flat = Join-Path $sb "flat"
    $flatReport = Join-Path $sb "flat.md"
    New-Item -ItemType Directory -Force -Path (Join-Path $flat "lib") | Out-Null
    function Wf($rel, $text) {
        $p = Join-Path $flat $rel
        $d = Split-Path -Parent $p
        if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
    }
    Wf 'menu.bat' "@echo off`r`npython tool_runner.py`r`n"
    Wf 'tool_runner.py' "import lib.core`r`n`ndef main():`r`n    return 0`r`n`nif __name__ == '__main__':`r`n    main()`r`n"
    Wf 'lib/core.py' "VALUE = 1`r`n"
    Wf 'self_checks_tests.py' "import unittest`r`n`nclass T(unittest.TestCase):`r`n    def test_a(self):`r`n        self.assertEqual(1, 1)`r`n"
    # 注意：这里调的是 $Script 本体，不是上面那个码页壳 —— 壳里的 -RepoPath 是写死给第一个夹具的，
    # 拿它跑扁平仓会静默地又去跑第一个仓（第一版就这么错过了）。R9/R10 与编码无关，不需要壳。
    $prev2 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $p2 = & $sh ($shArgs + [string[]]@($Script, '-RepoPath', $flat, '-OutFile', $flatReport, '-TopN', '10')) 2>&1 | Out-String
        $rc2 = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev2 }
    if ($rc2 -eq 0 -and (Test-Path -LiteralPath $flatReport)) {
        $t2 = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($flatReport)) -replace '^﻿', ''
        function Sec2($n) { $m = [regex]::Match($t2, "(?ms)^## $n\..*?(?=^## \d|\z)"); if ($m.Success) { return $m.Value } return "" }
        Chk 'R9 扁平仓要点名测试模块' (((Sec2 5) -match 'self_checks_tests\.py') -and ((Sec2 5) -notmatch '两路都没命中')) "第 5 节点名了自定义测试模块，且没走假结论分支"
        Chk 'R10 结构判据要认出入口' (((Sec2 6) -match 'tool_runner\.py') -and ((Sec2 6) -match 'menu\.bat')) "第 6 节含 tool_runner.py（__main__）与 menu.bat（仓根批处理）"
        Chk 'R10b 入口点非空' ((Sec2 6) -match '(?m)^-\s') "第 6 节有候选条目"
    } else {
        Chk 'R9 扁平仓要点名测试模块' $false "扁平仓这一跑就没成功（rc=$rc2），断言无从做起"
        Chk 'R10 结构判据要认出入口' $false "同上"
    }

    # R7 报告必须能按严格 UTF-8 解码（BOM 允许，乱码不允许）
    $strict = $true
    try { [System.Text.Encoding]::GetEncoding('utf-8', [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback).GetString($bytes) | Out-Null }
    catch { $strict = $false }
    Chk 'R7 严格 UTF-8 解码' $strict "$($bytes.Length) 字节"

    # R8 表头写"相对路径"，内容就必须真是相对的：不得带盘符、不得以 / 开头、不得含根目录前缀
    #     （v1.1 之前 scc 分支直接把 Location 塞进去，那是绝对路径 —— 列名与内容对不上）
    $rootN = $repo.Replace('\', '/')
    $paths = @()
    foreach ($r in (Rows (Sec 2))) { if ($r -match '`([^`]+)`') { $paths += $matches[1] } }
    foreach ($r in (Sec 6 -split "`r?`n")) { if ($r -match '^-\s+`([^`]+)`') { $paths += $matches[1] } }
    $abs = @($paths | Where-Object { $_ -match '^[A-Za-z]:' -or $_.StartsWith('/') -or $_ -like "*$rootN*" })
    Chk 'R8 路径列名副其实' ($abs.Count -eq 0 -and $paths.Count -gt 0) ("共 $($paths.Count) 条，绝对/带根前缀 $($abs.Count) 条$(if($abs.Count){'：'+(($abs|Select-Object -First 2) -join ' ')})")
    # R8b 相对口径要与沙箱一致（正斜杠、不含根）
    Chk 'R8b 相对形如 src/x' (@($paths | Where-Object { $_ -match '^src[\\/]' }).Count -gt 0) "样本: $(($paths | Select-Object -First 3) -join ' , ')"
} finally {
    if ($KeepSandbox) { Write-Host "[recon] 沙箱留着：$sb" }
    elseif (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
}
Write-Host ("")
if ($bad -gt 0) { Write-Host "[recon] 失败 $bad 项 / 通过 $pass 项 / SKIP $skip"; exit 1 }
Write-Host "[recon] 全部通过（$pass 项，SKIP $skip）。"
exit 0
