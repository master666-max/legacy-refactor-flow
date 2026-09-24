# 样例：侦察报告长这样

> 下面两份都是 `scripts/phase0-recon.ps1` **v1.2 的真实输出**，扫的对象是本仓自己的一份克隆。
> 唯一改动是把开头的绝对路径换成 `<扫描目标>` 占位符——第 2、6 节里的路径本来就是相对口径（v1.2 起统一）。
> 留两份是因为统计来源会走不同分支，报告形状不一样：

| | 数据来源 | 什么时候会看到 |
|---|---|---|
| 第一份 | `scc` + `code-maat` | 外部工具在位（推荐） |
| 第二份 | 内置兜底 + 内置 `git log` | 一个外部工具都没装；报告顶部会明写来源，第 8 节列出建议安装的件 |

---

## 一、外部工具在位

# 侦察报告：legacy-refactor-flow

- 路径：`<扫描目标>`
- 生成时间：2026-09-28 05:36
- **统计来源：scc**（scc > tokei > cloc > 内置兜底）
- **变更热力来源：code-maat**（code-maat > 内置 git log）
- 文件总数：13（已排除 node_modules/.git/dist 等噪声目录）
- 代码文件：6，测试文件：4，测试占比：66.7%
- 代码行数：1928
- git：分支 main / 提交数 5 / 最新 2026-09-28 test: 装 tests/ 自测夹具，把"我验过"换成你能复跑的东西

## 1. 语言分布

| 语言 | 文件数 | 行数 | 代码行 | 复杂度 |
|---|---|---|---|---|
| Powershell | 6 | 1019 | 783 | 364 |
| Markdown | 5 | 888 | 648 | 0 |
| License | 1 | 21 | 17 | 0 |

## 2. 体量最大的 20 个文件（重构优先候选）

| 行数 | 复杂度 | 相对路径 |
|---|---|---|
| 365 | 0 | `references/REFACTOR-RUNBOOK.md` |
| 270 | 86 | `scripts/phase0-recon.ps1` |
| 242 | 101 | `scripts/hooks-ledger.ps1` |
| 205 | 57 | `tests/check-recon.ps1` |
| 170 | 58 | `tests/check-ledger-lifecycle.ps1` |
| 161 | 0 | `README.md` |
| 140 | 0 | `SKILL.md` |
| 128 | 0 | `references/EXAMPLE-recon-report.md` |
| 97 | 49 | `tests/check-encoding.ps1` |
| 94 | 0 | `references/COMMUNITY-MAP.md` |
| 35 | 13 | `tests/run-all.ps1` |
| 21 | 0 | `LICENSE` |

## 3. 近 12 个月变更最频繁的文件（= 真正的风险热点）

| 变更次数 | 文件 |
|---|---|
| 3 | `README.md` |
| 2 | `SKILL.md` |
| 2 | `scripts/hooks-ledger.ps1` |
| 2 | `references/EXAMPLE-recon-report.md` |
| 2 | `scripts/phase0-recon.ps1` |
| 1 | `references/REFACTOR-RUNBOOK.md` |
| 1 | `tests/check-ledger-lifecycle.ps1` |
| 1 | `tests/run-all.ps1` |
| 1 | `.gitattributes` |
| 1 | `references/COMMUNITY-MAP.md` |
| 1 | `tests/check-recon.ps1` |
| 1 | `LICENSE` |
| 1 | `tests/check-encoding.ps1` |

## 4. 重复代码

未检测（加 -WithDup 开启 jscpd）

## 5. 测试基础设施现状

检测到：tests

## 6. 入口点候选

（未按常见命名匹配到，需手工枚举 CLI / HTTP 路由 / cron）

## 7. 一级目录（模块切分候选）

| 目录 | 文件数 |
|---|---|
| tests | 4 |
| references | 3 |
| scripts | 2 |

## 8. 下一步（本机尚未安装的工具）

以下工具未安装 —— 它们能替代本报告里的兜底实现，建议装上：

- `madge`
- `dependency-cruiser`

推荐动作：

1. 把第 1~3 节的基线数字抄进 `SCOPE.md`。
2. 对第 3 节的热点文件先装图谱 MCP 查调用者，**不要直接读源码**。
3. 第 6 节的入口点逐个分类 LIVE / DEAD / UNKNOWN（再叠加 Addy Osmani 的绿/黄/红风险分区）。
4. 用 `RefactoringMiner` 挖这个仓库历史上的重构记录，能看出团队既有习惯。

---

## 二、外部工具全缺（内置兜底）

注意第二份的三点不同：**语言名变成扩展名**（`.py` 而非 `Python`）、**没有复杂度列**、
**建议安装清单变长**。这就是脚本为什么坚持在报告顶部标数据来源——兜底数字能用，但不能当成 scc 级的事实。

# 侦察报告：legacy-refactor-flow

- 路径：`<扫描目标>`
- 生成时间：2026-09-28 05:37
- **统计来源：内置兜底**（scc > tokei > cloc > 内置兜底）
- **变更热力来源：内置 git log**（code-maat > 内置 git log）
- 文件总数：13（已排除 node_modules/.git/dist 等噪声目录）
- 代码文件：6，测试文件：4，测试占比：66.7%
- 代码行数：944
- git：分支 main / 提交数 5 / 最新 2026-09-28 test: 装 tests/ 自测夹具，把"我验过"换成你能复跑的东西

## 1. 语言分布

| 语言 | 文件数 | 行数 | 代码行 | 复杂度 |
|---|---|---|---|---|
| .ps1 | 6 | 944 | 944 |  |

## 2. 体量最大的 20 个文件（重构优先候选）

| 行数 | 复杂度 | 相对路径 |
|---|---|---|
| 258 |  | `scripts/phase0-recon.ps1` |
| 221 |  | `scripts/hooks-ledger.ps1` |
| 186 |  | `tests/check-recon.ps1` |
| 159 |  | `tests/check-ledger-lifecycle.ps1` |
| 87 |  | `tests/check-encoding.ps1` |
| 33 |  | `tests/run-all.ps1` |

## 3. 近 12 个月变更最频繁的文件（= 真正的风险热点）

| 变更次数 | 文件 |
|---|---|
| 3 | `README.md` |
| 2 | `scripts/hooks-ledger.ps1` |
| 2 | `SKILL.md` |
| 2 | `references/EXAMPLE-recon-report.md` |
| 2 | `scripts/phase0-recon.ps1` |
| 1 | `LICENSE` |
| 1 | `.gitattributes` |
| 1 | `references/REFACTOR-RUNBOOK.md` |
| 1 | `references/COMMUNITY-MAP.md` |
| 1 | `tests/check-recon.ps1` |
| 1 | `tests/run-all.ps1` |
| 1 | `tests/check-encoding.ps1` |
| 1 | `tests/check-ledger-lifecycle.ps1` |

## 4. 重复代码

未检测（加 -WithDup 开启 jscpd）

## 5. 测试基础设施现状

检测到：tests

## 6. 入口点候选

（未按常见命名匹配到，需手工枚举 CLI / HTTP 路由 / cron）

## 7. 一级目录（模块切分候选）

| 目录 | 文件数 |
|---|---|
| tests | 4 |
| references | 3 |
| scripts | 2 |

## 8. 下一步（本机尚未安装的工具）

以下工具未安装 —— 它们能替代本报告里的兜底实现，建议装上：

- `scc`
- `tokei`
- `cloc`
- `code-maat`
- `jscpd`
- `lizard`
- `radon`
- `ast-grep`
- `sg`
- `semgrep`
- `gitleaks`
- `git-sizer`
- `madge`
- `dependency-cruiser`

推荐动作：

1. 把第 1~3 节的基线数字抄进 `SCOPE.md`。
2. 对第 3 节的热点文件先装图谱 MCP 查调用者，**不要直接读源码**。
3. 第 6 节的入口点逐个分类 LIVE / DEAD / UNKNOWN（再叠加 Addy Osmani 的绿/黄/红风险分区）。
4. 用 `RefactoringMiner` 挖这个仓库历史上的重构记录，能看出团队既有习惯。
