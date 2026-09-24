<#
.SYNOPSIS
  phase0-recon.ps1 v2 —— 屎山重构侦察调度器（对应 aim42 · Analyze 阶段）
.DESCRIPTION
  优先调用成熟的现成开源工具，不重复造轮子：
    语言/体量统计 : scc > tokei > cloc > 内置兜底
    变更热力/热点 : code-maat > 内置 git log 兜底
    重复代码      : jscpd（需 -WithDup 显式开启）
  只用内置实现时，报告顶部会标注「数据来源：内置兜底」。
.EXAMPLE
  ./phase0-recon.ps1 -RepoPath D:\my\legacy -OutFile recon-report.md
.EXAMPLE
  ./phase0-recon.ps1 -RepoPath . -WithDup
#>
param(
    [Parameter(Mandatory = $true)][string]$RepoPath,
    [string]$OutFile = "recon-report.md",
    [int]$TopN = 20,
    [switch]$WithDup
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $RepoPath)) { throw "路径不存在: $RepoPath" }
$root = (Resolve-Path -LiteralPath $RepoPath).Path
$nl = [Environment]::NewLine
$tick = [char]96
$bs = [char]92
$fs = [char]47
Write-Host "[recon] root = $root"

# ---------- 0. 工具探测 ----------
$want = @('scc','tokei','cloc','code-maat','jscpd','lizard','radon','ast-grep','sg','semgrep','gitleaks','git-sizer','madge','dependency-cruiser','git')
$tools = @{}
foreach ($n in $want) { $tools[$n] = [bool](Get-Command $n -ErrorAction SilentlyContinue) }
$missing = @($want | Where-Object { -not $tools[$_] -and $_ -ne 'git' })
Write-Host ("[recon] 已装: " + (($want | Where-Object { $tools[$_] }) -join ', '))

$noise = @('node_modules','.git','dist','build','target','vendor','__pycache__','.venv','venv','.next','.nuxt','out','bin','obj','.mypy_cache','.pytest_cache','.tox','htmlcov','.idea','.vscode','.dsh-reef','coverage','.gradle','.terraform')
$codeExt = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.java','.kt','.kts','.go','.rs','.cs','.php','.rb','.c','.h','.cc','.cpp','.hpp','.swift','.scala','.sh','.ps1','.sql','.vue','.svelte','.lua','.dart','.ex','.exs')
$testRe = '((^|[\\/_.-])(tests?|specs?)([\\/_.-]|$))|_test\.|\.test\.|\.spec\.'
$noiseRe = "[\\/](" + (($noise | ForEach-Object { [regex]::Escape($_) }) -join '|') + ")[\\/]"

$all = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $noiseRe })
$code = @($all | Where-Object { $codeExt -contains $_.Extension.ToLower() })
$test = @($code | Where-Object { $_.FullName -match $testRe })
$pct = 0
if ($code.Count -gt 0) { $pct = [math]::Round(100 * $test.Count / $code.Count, 1) }
Write-Host "[recon] 文件总数 $($all.Count) / 代码文件 $($code.Count)"

# ---------- 1. 语言与体量统计 ----------
$statSource = "内置兜底"
$langRows = New-Object System.Collections.Generic.List[object]
$fileRows = New-Object System.Collections.Generic.List[object]
$totalLines = 0

if ($tools['scc']) {
    try {
        $raw = (& scc --format json --no-cocomo --exclude-dir node_modules,.git,dist,build,target,vendor,out,bin,obj "$root" 2>$null | Out-String)
        $j = $raw | ConvertFrom-Json
        foreach ($e in $j) {
            if ($e.Language -eq 'Total') { continue }
            $langRows.Add([pscustomobject]@{ Name = $e.Language; Files = $e.Count; Lines = $e.Lines; Code = $e.Code; Cx = $e.Complexity })
            $totalLines += [int]$e.Lines
            if ($e.Files) { foreach ($f in $e.Files) { $fileRows.Add([pscustomobject]@{ Rel = $f.Location; Lines = (([int]$f.Code) + ([int]$f.Comment) + ([int]$f.Blank)); Cx = $f.Complexity }) } }
        }
        $statSource = "scc"
    } catch { $statSource = "内置兜底" }
}
if ($statSource -eq "内置兜底" -and $tools['tokei']) {
    try {
        $j = (& tokei --output json "$root" 2>$null | Out-String) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            if ($p.Name -eq 'Total') { continue }
            $v = $p.Value
            $langRows.Add([pscustomobject]@{ Name = $p.Name; Files = @($v.reports).Count; Lines = ([int]$v.code + [int]$v.comments + [int]$v.blanks); Code = $v.code; Cx = $null })
            $totalLines += ([int]$v.code + [int]$v.comments + [int]$v.blanks)
            foreach ($rep in $v.reports) { $fileRows.Add([pscustomobject]@{ Rel = $rep.name; Lines = ([int]$rep.stats.code + [int]$rep.stats.comments + [int]$rep.stats.blanks); Cx = $null }) }
        }
        $statSource = "tokei"
    } catch { $statSource = "内置兜底" }
}
if ($statSource -eq "内置兜底" -and $tools['cloc']) {
    try {
        $j = (& cloc --json --quiet --exclude-dir=node_modules,.git,dist,build,target,vendor "$root" 2>$null | Out-String) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            if ($p.Name -eq 'header' -or $p.Name -eq 'SUM') { continue }
            $v = $p.Value
            $langRows.Add([pscustomobject]@{ Name = $p.Name; Files = $v.nFiles; Lines = ([int]$v.code + [int]$v.comment + [int]$v.blank); Code = $v.code; Cx = $null })
            $totalLines += ([int]$v.code + [int]$v.comment + [int]$v.blank)
        }
        $statSource = "cloc"
    } catch { $statSource = "内置兜底" }
}
if ($statSource -eq "内置兜底") {
    $cap = 6000
    $agg = @{}
    $i = 0
    foreach ($f in $code) {
        if ($i -ge $cap) { break }
        $i++
        $n = 0
        try { $n = (Get-Content -LiteralPath $f.FullName -ErrorAction Stop | Measure-Object -Line).Lines } catch { $n = 0 }
        $ext = $f.Extension.ToLower()
        if (-not $agg.ContainsKey($ext)) { $agg[$ext] = @{ Files = 0; Lines = 0 } }
        $agg[$ext].Files++
        $agg[$ext].Lines += $n
        $totalLines += $n
        $fileRows.Add([pscustomobject]@{ Rel = $f.FullName.Replace($root, "").TrimStart($bs, $fs); Lines = $n; Cx = $null })
    }
    foreach ($k in $agg.Keys) { $langRows.Add([pscustomobject]@{ Name = $k; Files = $agg[$k].Files; Lines = $agg[$k].Lines; Code = $agg[$k].Lines; Cx = $null }) }
}
Write-Host "[recon] 统计来源 $statSource / 总行数 $totalLines"

# ---------- 2. 变更热力 ----------
$churnSource = "无"
$churn = @()
if (Test-Path -LiteralPath (Join-Path $root ".git")) {
    if ($tools['code-maat']) {
        try {
            $log = Join-Path ([System.IO.Path]::GetTempPath()) "recon-cm-input.log"
            git -c core.quotepath=false -C $root log --pretty=format:"[%h] %an %ad %s" --date=short --numstat 2>$null | Set-Content -LiteralPath $log -Encoding UTF8
            $csv = (& code-maat -l $log -c git2 -a revisions 2>$null | Out-String)
            $lines = $csv -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^entity' }
            $churn = @($lines | Select-Object -First $TopN | ForEach-Object { $p = $_ -split ','; [pscustomobject]@{ Count = $p[1]; Name = $p[0] } })
            $churnSource = "code-maat"
        } catch { $churnSource = "无" }
    }
    if ($churnSource -eq "无") {
        try {
            $churn = @(git -c core.quotepath=false -C $root log --since="12 months ago" --name-only --pretty=format: 2>$null |
                Where-Object { $_ -and $_.Trim() -ne "" } | Group-Object | Sort-Object Count -Descending | Select-Object -First $TopN)
            $churnSource = "内置 git log"
        } catch { $churnSource = "无" }
    }
}
$gitInfo = "（不是 git 仓库 / 无历史）"
if (Test-Path -LiteralPath (Join-Path $root ".git")) {
    try {
        $br = (git -c core.quotepath=false -C $root rev-parse --abbrev-ref HEAD 2>$null)
        $last = (git -c core.quotepath=false -C $root log -1 --pretty=format:"%ad %s" --date=short 2>$null)
        $cnt = (git -c core.quotepath=false -C $root rev-list --count HEAD 2>$null)
        $gitInfo = "分支 $br / 提交数 $cnt / 最新 $last"
    } catch { $gitInfo = "git 读取失败" }
}

# ---------- 3. 重复代码（可选） ----------
$dupNote = "未检测（加 -WithDup 开启 jscpd）"
if ($WithDup -and $tools['jscpd']) {
    try {
        $dupOut = (& jscpd --min-lines 15 --reporters json --output "$env:TEMP\jscpd-recon" --ignore "**/node_modules/**" "$root" 2>$null | Out-String)
        $dupNote = "已用 jscpd 运行（min-lines 15），原始 JSON 见 $env:TEMP\jscpd-recon"
    } catch { $dupNote = "jscpd 运行失败" }
} elseif ($WithDup) { $dupNote = "请求了 -WithDup 但未安装 jscpd" }

# ---------- 4. 基础设施 / 入口点 / 目录 ----------
$entries = @($code | Where-Object { $b = $_.BaseName.ToLower(); ($b -eq 'main' -or $b -eq 'index' -or $b -eq 'app' -or $b -eq 'server' -or $b -eq 'cli' -or $b -eq 'program' -or $b -eq 'manage' -or $b -eq 'bootstrap' -or $b -eq 'wsgi' -or $b -eq 'asgi' -or $b -eq 'start') })
$infra = @()
foreach ($m in @('package.json','pytest.ini','pyproject.toml','setup.cfg','tox.ini','Makefile','go.mod','Cargo.toml','pom.xml','build.gradle','composer.json','requirements.txt','Dockerfile','docker-compose.yml','.github','.gitlab-ci.yml','Jenkinsfile','conftest.py','tests','test')) {
    if (Test-Path -LiteralPath (Join-Path $root $m)) { $infra += $m }
}
$topDirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $noiseRe } |
    ForEach-Object { $c = @(Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue).Count; [pscustomobject]@{ Name = $_.Name; Files = $c } } |
    Sort-Object Files -Descending | Select-Object -First 15)

# ---------- 5. 出报告 ----------
$L = New-Object System.Collections.Generic.List[string]
$L.Add("# 侦察报告：" + (Split-Path $root -Leaf))
$L.Add("")
$L.Add("- 路径：" + $tick + $root + $tick)
$L.Add("- 生成时间：" + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
$L.Add("- **统计来源：$statSource**（scc > tokei > cloc > 内置兜底）")
$L.Add("- **变更热力来源：$churnSource**（code-maat > 内置 git log）")
$L.Add("- 文件总数：$($all.Count)（已排除 node_modules/.git/dist 等噪声目录）")
$L.Add("- 代码文件：$($code.Count)，测试文件：$($test.Count)，测试占比：$pct%")
$L.Add("- 代码行数：$totalLines")
$L.Add("- git：$gitInfo")
$L.Add("")
$L.Add("## 1. 语言分布")
$L.Add("")
$L.Add("| 语言 | 文件数 | 行数 | 代码行 | 复杂度 |")
$L.Add("|---|---|---|---|---|")
foreach ($r in ($langRows | Sort-Object Lines -Descending)) { $L.Add("| $($r.Name) | $($r.Files) | $($r.Lines) | $($r.Code) | $($r.Cx) |") }
$L.Add("")
$L.Add("## 2. 体量最大的 $TopN 个文件（重构优先候选）")
$L.Add("")
$L.Add("| 行数 | 复杂度 | 相对路径 |")
$L.Add("|---|---|---|")
foreach ($r in ($fileRows | Sort-Object Lines -Descending | Select-Object -First $TopN)) { $L.Add("| $($r.Lines) | $($r.Cx) | " + $tick + $r.Rel + $tick + " |") }
$L.Add("")
$L.Add("## 3. 近 12 个月变更最频繁的文件（= 真正的风险热点）")
$L.Add("")
if ($churn.Count -gt 0) {
    $L.Add("| 变更次数 | 文件 |")
    $L.Add("|---|---|")
    foreach ($c in $churn) { $L.Add("| $($c.Count) | " + $tick + $c.Name + $tick + " |") }
} else { $L.Add("（无 git 历史）") }
$L.Add("")
$L.Add("## 4. 重复代码")
$L.Add("")
$L.Add($dupNote)
$L.Add("")
$L.Add("## 5. 测试基础设施现状")
$L.Add("")
if ($infra.Count -gt 0) { $L.Add("检测到：" + ($infra -join ", ")) } else { $L.Add("**未检测到任何测试/构建配置文件 —— 从零开始造裁判。**") }
$L.Add("")
$L.Add("## 6. 入口点候选")
$L.Add("")
if ($entries.Count -gt 0) { foreach ($e in ($entries | Select-Object -First 25)) { $L.Add("- " + $tick + $e.FullName.Replace($root, "").TrimStart($bs, $fs) + $tick) } } else { $L.Add("（未按常见命名匹配到，需手工枚举 CLI / HTTP 路由 / cron）") }
$L.Add("")
$L.Add("## 7. 一级目录（模块切分候选）")
$L.Add("")
$L.Add("| 目录 | 文件数 |")
$L.Add("|---|---|")
foreach ($d in $topDirs) { $L.Add("| $($d.Name) | $($d.Files) |") }
$L.Add("")
$L.Add("## 8. 下一步（本机尚未安装的工具）")
$L.Add("")
if ($missing.Count -gt 0) {
    $L.Add("以下工具未安装 —— 它们能替代本报告里的兜底实现，建议装上：")
    $L.Add("")
    foreach ($m in $missing) { $L.Add("- " + $tick + $m + $tick) }
} else { $L.Add("现成工具已齐备。") }
$L.Add("")
$L.Add("推荐动作：")
$L.Add("")
$L.Add("1. 把第 1~3 节的基线数字抄进 " + $tick + "SCOPE.md" + $tick + "。")
$L.Add("2. 对第 3 节的热点文件先装图谱 MCP 查调用者，**不要直接读源码**。")
$L.Add("3. 第 6 节的入口点逐个分类 LIVE / DEAD / UNKNOWN（再叠加 Addy Osmani 的绿/黄/红风险分区）。")
$L.Add("4. 用 " + $tick + "RefactoringMiner" + $tick + " 挖这个仓库历史上的重构记录，能看出团队既有习惯。")
$L.Add("")

$target = $OutFile
if (-not [System.IO.Path]::IsPathRooted($OutFile)) { $target = Join-Path (Get-Location).Path $OutFile }
Set-Content -LiteralPath $target -Value ($L -join $nl) -Encoding UTF8
Write-Host "[recon] 报告已写入 $target"
Write-Host "[recon] 概要：$statSource / $($code.Count) 文件 / $totalLines 行 / 测试占比 $pct%"
if ($missing.Count -gt 0) { Write-Host "[recon] 建议安装：$($missing -join ', ')" }
