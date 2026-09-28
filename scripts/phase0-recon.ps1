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
    [switch]$WithDup,
    # 噪声目录（逗号分隔目录名；含 `/` 的按路径段匹配，如 build/out）。
    # 注意：默认表把 `build` 整个排除，对"build/ 是真代码"的仓库会漏统计——
    # 这类仓库请显式传入自己的列表（例如 build/out 只排生成物）。
    [string]$ExcludeDirs = "node_modules,.git,dist,build,target,vendor,out,bin,obj"
)

$ErrorActionPreference = "Stop"
# 子进程（git 等）输出按 UTF-8 解码：PS 5.1 默认按控制台 OEM 代码页解，中文提交信息会整片乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if (-not (Test-Path -LiteralPath $RepoPath)) { throw "路径不存在: $RepoPath" }
$root = (Resolve-Path -LiteralPath $RepoPath).Path
$nl = [Environment]::NewLine
$tick = [char]96

# 把绝对路径削成相对 $root 的形式：scc 的 Files[].Location 是绝对路径，而内置兜底给的是相对的，
# 同一列两种口径会让报告里的"相对路径"名不副实。大小写不敏感比对（Windows 上路径不分大小写）。
function Get-Rel([string]$p) {
    if (-not $p) { return "" }
    $a = $p.Replace('\', '/'); $b = $root.Replace('\', '/')
    if ($a.Length -gt $b.Length -and [string]::Compare($a.Substring(0, $b.Length), $b, [StringComparison]::OrdinalIgnoreCase) -eq 0) {
        $a = $a.Substring($b.Length)
    }
    return $a.TrimStart('/')
}
Write-Host "[recon] root = $root"

# ---------- 0. 工具探测 ----------
$want = @('scc','tokei','cloc','code-maat','jscpd','lizard','radon','ast-grep','sg','semgrep','gitleaks','git-sizer','madge','dependency-cruiser','git')
$tools = @{}
foreach ($n in $want) { $tools[$n] = [bool](Get-Command $n -ErrorAction SilentlyContinue) }
$missing = @($want | Where-Object { -not $tools[$_] -and $_ -ne 'git' })
Write-Host ("[recon] 已装: " + (($want | Where-Object { $tools[$_] }) -join ', '))

$noise = @('node_modules','.git','__pycache__','.venv','venv','.next','.nuxt','.mypy_cache','.pytest_cache','.tox','htmlcov','.idea','.vscode','.dsh-reef','coverage','.gradle','.terraform') + @($ExcludeDirs -split ',' | Where-Object { $_ -ne '' })
$codeExt = @('.ts','.tsx','.js','.jsx','.mjs','.cjs','.py','.java','.kt','.kts','.go','.rs','.cs','.php','.rb','.c','.h','.cc','.cpp','.hpp','.swift','.scala','.sh','.ps1','.sql','.vue','.svelte','.lua','.dart','.ex','.exs')
$testRe = '((^|[\\/_.-])(tests?|specs?)([\\/_.-]|$))|_test\.|\.test\.|\.spec\.'
# 含 `/` 的条目按路径段匹配（`/` 同时匹配两种分隔符），其余按单级目录名匹配
$noiseRe = "[\\/](" + (($noise | ForEach-Object { ([regex]::Escape($_)) -replace '/', '[\\/]' }) -join '|') + ")[\\/]"

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
        # 两处必需：① --by-file —— 不加时 scc 的 JSON 里 Files 数组恒为空，体量表会整表空白；
        #          ② 字段名是 Name 不是 Language —— 用 Language 会得到空语言名。
        $raw = (& scc --format json --no-cocomo --by-file --exclude-dir $ExcludeDirs "$root" 2>$null | Out-String)
        $j = $raw | ConvertFrom-Json
        foreach ($e in $j) {
            if ($e.Name -eq 'Total') { continue }
            $langRows.Add([pscustomobject]@{ Name = $e.Name; Files = $e.Count; Lines = $e.Lines; Code = $e.Code; Cx = $e.Complexity })
            $totalLines += [int]$e.Lines
            if ($e.Files) { foreach ($f in $e.Files) { $fileRows.Add([pscustomobject]@{ Rel = (Get-Rel $f.Location); Lines = (([int]$f.Code) + ([int]$f.Comment) + ([int]$f.Blank)); Cx = $f.Complexity }) } }
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
        $fileRows.Add([pscustomobject]@{ Rel = (Get-Rel $f.FullName); Lines = $n; Cx = $null })
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
            # 日志写成「无 BOM」UTF-8：PS 5.1 的 Set-Content -Encoding UTF8 会加 BOM，部分解析器在首行报错
            $raw = (git -c core.quotepath=false -C $root log --pretty=format:"[%h] %an %ad %s" --date=short --numstat 2>$null | Out-String)
            [System.IO.File]::WriteAllText($log, $raw, (New-Object System.Text.UTF8Encoding($false)))
            # 用 `-c git`：本版 standalone jar 的 git2 解析器对规范格式也报 Parse error，git 解析器接受同一份日志
            $csv = (& code-maat -l $log -c git -a revisions 2>$null | Out-String)
            $lines = @($csv -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^entity' })
            # 只采信真像 CSV 的输出：否则 java 的报错文本会被当成数据写进报告（静默失败）
            $ok = ($csv -match '(?m)^entity,') -and (@($lines | Where-Object { $_ -match ',\d+\s*$' }).Count -gt 0)
            if ($ok) {
                $churn = @($lines | Select-Object -First $TopN | ForEach-Object { $p = $_ -split ','; [pscustomobject]@{ Count = $p[1]; Name = $p[0] } })
                $churnSource = "code-maat"
            }
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
# 入口点不能靠**名字**认：真实 CLI 仓的模块可以叫任何名字（本机实测：一个 9 模块的工具链
# 按名字白名单命中 0 个，而按结构判据命中 5 个）。改成两路并集：名字 + 结构。
$nameHits = @($code | Where-Object { $b = $_.BaseName.ToLower(); ($b -eq 'main' -or $b -eq 'index' -or $b -eq 'app' -or $b -eq 'server' -or $b -eq 'cli' -or $b -eq 'program' -or $b -eq 'manage' -or $b -eq 'bootstrap' -or $b -eq 'wsgi' -or $b -eq 'asgi' -or $b -eq 'start') })
$entryRows = New-Object System.Collections.Generic.List[object]
foreach ($f in $nameHits) {
    $entryRows.Add([pscustomobject]@{ Rel = (Get-Rel $f.FullName); Why = '名字白名单' })
}
# bat / cmd 放在仓根就是给人双击或调用的入口，不看名字
foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLower() -in @('.bat', '.cmd') })) {
    $entryRows.Add([pscustomobject]@{ Rel = (Get-Rel $f.FullName); Why = '仓根批处理入口' })
}
# 结构判据：py 的 __main__ 守卫、任何脚本的 shebang、js 的 require.main
$guardCap = 400
$guardScanned = 0
$guardTrunc = $false
$cands = @($code | Where-Object { $_.Length -lt 400000 -and $_.Extension.ToLower() -in @('.py', '.sh', '.rb', '.pl', '.js', '.mjs', '.cjs', '.ts') } | Sort-Object Length -Descending)
$already = @{}
foreach ($r in $entryRows) { $already[$r.Rel.ToLower()] = 1 }
foreach ($f in $cands) {
    if ($guardScanned -ge $guardCap) { $guardTrunc = $true; break }
    $rel = (Get-Rel $f.FullName)
    if ($already.ContainsKey($rel.ToLower())) { continue }
    $guardScanned++
    $hit = ''
    $head = ''
    try { $head = @(Get-Content -LiteralPath $f.FullName -TotalCount 2 -ErrorAction Stop) -join "`n" } catch {}
    if ($head -match '(?m)^#!') { $hit = 'shebang' }
    if (-not $hit -and $f.Extension.ToLower() -eq '.py') {
        if (Select-String -LiteralPath $f.FullName -Pattern '__name__\s*==\s*["'']__main__' -Quiet -ErrorAction SilentlyContinue) { $hit = '__main__ 守卫' }
    }
    if (-not $hit -and $f.Extension.ToLower() -in @('.js', '.mjs', '.cjs')) {
        if (Select-String -LiteralPath $f.FullName -Pattern 'require\.main\s*===\s*module' -Quiet -ErrorAction SilentlyContinue) { $hit = 'require.main 守卫' }
    }
    if ($hit) { $entryRows.Add([pscustomobject]@{ Rel = $rel; Why = $hit }); $already[$rel.ToLower()] = 1 }
}
# 注意：@($list) 作用在 Generic.List[object] 上，本机 PowerShell 会抛
# ArgumentException「参数类型不匹配」（最小复现过）—— 要成数组就走 ToArray()。
$entries = $entryRows.ToArray()
$infra = @()
$infraNames = @('package.json','pytest.ini','pyproject.toml','setup.cfg','tox.ini','Makefile','go.mod','Cargo.toml','pom.xml','build.gradle','composer.json','requirements.txt','Dockerfile','docker-compose.yml','.github','.gitlab-ci.yml','Jenkinsfile','conftest.py','tests','test')
foreach ($m in $infraNames) {
    if (Test-Path -LiteralPath (Join-Path $root $m)) { $infra += $m }
}
# 多子项目仓库（monorepo）的测试/构建配置通常在各子目录里：根目录没有≠从零开始，再扫一级
foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $noise -notcontains $_.Name })) {
    foreach ($m in @('pytest.ini','pyproject.toml','setup.cfg','conftest.py','tests','test','package.json','Makefile','requirements.txt','tox.ini')) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName $m)) { $infra += ($d.Name + "/" + $m) }
    }
}
$topDirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $noise -notcontains $_.Name } |
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
if ($infra.Count -gt 0) {
    $L.Add("命中配置文件：" + ($infra -join ", "))
    if ($test.Count -gt 0) { $L.Add("另外按命名/结构识别出 " + $test.Count + " 个测试文件。") }
} elseif ($test.Count -gt 0) {
    # 关键：报告头部已经算出"测试文件 N 个"，这一节绝不能再说"从零开始造裁判"——
    # 那是同一份报告里的自相矛盾（本机在一个真实工具链仓上实测发生过）。
    $L.Add("**配置名单一个没命中，但按命名/结构识别出 " + $test.Count + " 个测试文件 —— 这不是从零开始。** 前 10 个：")
    foreach ($t in ($test | Select-Object -First 10)) { $L.Add("- " + $tick + (Get-Rel $t.FullName) + $tick) }
    $L.Add("")
    $L.Add("> 自带 runner 的仓（没有 pytest.ini / package.json 那类配置文件）就是这种形状。先去 README 或维护文档里找它的跑法，再决定要不要补裁判。")
} else {
    $L.Add("**配置文件名单与结构判据两路都没命中 —— 这才叫从零开始造裁判。**")
}
$L.Add("")
$L.Add("## 6. 入口点候选")
$L.Add("")
if ($entries.Count -gt 0) {
    $L.Add("共 " + $entries.Count + " 个（判据：名字白名单 / 仓根批处理 / shebang / ``__main__`` 守卫）")
    $L.Add("")
    foreach ($e in ($entries | Select-Object -First 25)) { $L.Add("- " + $tick + $e.Rel + $tick + "  （判据：" + $e.Why + "）") }
    if ($guardTrunc) {
        $L.Add("")
        $L.Add("> 结构判据只扫了前 $guardCap 个脚本文件（按体量降序），**大仓没扫完** ⇒ 这份清单不完备，别按「全部入口」引用它。")
    }
} else {
    $L.Add("（名字白名单与结构判据两路都没命中 —— 入口点要从别处取：build/打包配置里的 main/bin 字段、CI 的运行命令、进程清单，或者直接问用户。）")
}
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
