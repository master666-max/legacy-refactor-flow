# legacy-refactor-flow

> 遗留系统重构的通用流程 skill —— **自带强制拆除，用完不留钩子。**

用于把「没人懂 + 没测试 + 可能是 AI 写的屎山」安全改造的 agent skill。基于 2026 年的实证研究与社区十年积累的方法整理而成。

## 它解决什么

LLM 编码 agent 掉进遗留系统的根本原因不是智力不足，而是**上下文碎片化与 token 预算耗尽**。所以本 skill 的重点不是「让 AI 更聪明」，而是三件事：

1. **先造裁判，再动代码** —— 没有可验证的变更探测器，任何改动都是赌博。
2. **先减量，再重构** —— 真屎山里常有 40%~70% 是死代码；删掉不需要理解的代码，是零风险、最高回报的一步。
3. **AI 提出假设，运行负责裁决** —— 永远不让模型凭「理解」手写测试期望值。

## 附加硬约束：用完必须拆干净

本 skill **不允许留下任何持续性钩子**。流程中创建的任何跨会话 / 跨进程 / 跨仓库生效的东西（MCP 注册、git hook、CI 门、常驻索引、daemon、环境变量、后台任务）都必须：

- 在**创建的同一刻**登记进台账（含原文件 SHA256 备份）
- 收尾时 `-Teardown` 预演 → `-Teardown -Apply` 执行 → `-Verify` 逐条核对
- `-Verify` 任一未清干净即返回非零退出码，无法在绿色下蒙混过关

## 流程

```
A 立界 → B 测绘 → C 定活 → D 造裁判 → E 小步改
```

A~D 是纯投入期，**一行业务代码都不改**。跳过 D 直接进 E，就是复合重构失败率约 60% 的那批样本。

## 快速开始

```powershell
# 1) 侦察：语言分布、体量热点、变更热力、测试现状、入口点候选
./scripts/phase0-recon.ps1 -RepoPath D:\path\to\repo -OutFile recon-report.md

#    默认噪声表把 build/ 整个排除；若那个仓库的 build/ 是真代码，自己给一份列表（含 `/` 的按路径段匹配）
./scripts/phase0-recon.ps1 -RepoPath D:\path\to\repo -OutFile recon-report.md -ExcludeDirs "node_modules,.git,dist,target,vendor,bin,obj,build/out"

# 2) 登记一个持续性钩子（创建前先备份原文件）
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Register -Kind config -Path <钩子路径> -Action modified -Backup <备份路径>

# 3) 收尾：预演 → 执行 → 验证 → 通用扫描
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Teardown
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Teardown -Apply
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Verify
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Sweep -Repo <目标仓库>
```

## 安装

把仓库克隆到你的 skill 根目录下，**目录名保持 `legacy-refactor-flow`**：

| 平台 | 路径 |
|---|---|
| DeepSeek Harness（用户级） | `~/.dsh/skills/legacy-refactor-flow/` |
| DSH（项目级） | `<项目>/.dsh/skills/legacy-refactor-flow/` |
| Claude Code（用户级） | `~/.claude/skills/legacy-refactor-flow/` |

```powershell
git clone https://github.com/master666-max/legacy-refactor-flow.git "$HOME/.dsh/skills/legacy-refactor-flow"
```

## 目录

| 路径 | 作用 |
|---|---|
| `SKILL.md` | skill 入口：两条铁律、五步流程、钩子台账、强制拆除、残留物清单 |
| `scripts/hooks-ledger.ps1` | 台账登记 / 列表 / 预演 / 拆除 / 验证 / 通用扫描 |
| `scripts/phase0-recon.ps1` | 侦察调度器：优先调 scc/tokei/cloc/code-maat/jscpd，内置实现仅兜底并标注来源 |
| `references/REFACTOR-RUNBOOK.md` | 完整作战手册：阶段细节、出口条件、按语言工具矩阵、提示词模板 |
| `references/COMMUNITY-MAP.md` | 社区已有方法与流程图、现成工具地图、与 aim42 的对应关系 |
| `references/EXAMPLE-recon-report.md` | 侦察脚本的真实输出样例 |

## 依赖

- PowerShell 5.1+ 或 pwsh 7+（Windows / Linux / macOS 均可）
- 可选外部工具——**有则用，无则自动降级**：`scc` / `tokei` / `cloc`（语言统计）、`code-maat`（变更热力，需 Java）、`jscpd`（重复率）

### 编码契约（改这两个脚本时必须守住）

两个 `.ps1` 一律存成 **带 BOM 的 UTF-8 + CRLF**，脚本开头都有 `[Console]::OutputEncoding = UTF8`。少任何一条都会在"中文 Windows + Windows PowerShell 5.1"这个默认组合上出事：

| 约定 | 破了会怎样 |
|---|---|
| 带 BOM | PS 5.1 对无 BOM 的 `.ps1` 按 ANSI 代码页（中文机 = GBK）解码 → 中文注释与字符串变乱码 → 乱码字节撞坏语法树 → **ParserError，脚本完全不可用** |
| 脚本内设 `OutputEncoding = UTF8` | PS 5.1 默认按控制台 OEM 代码页输出 → 输出经管道/重定向给上层（agent、CI 日志）读时中文整片乱码，**等于没有证据** |
| `code-maat` 用 `-c git` 且日志写成无 BOM UTF-8 | 本版 standalone jar 的 `git2` 解析器对规范格式也报 `Parse error`；带 BOM 时连 `git` 解析器也在第 1 行第 1 列报错 |

`.gitattributes` 里的 `*.ps1 text eol=crlf` **只管换行符，不管编码**，管不住第一行那条。

## 变更记录

### v1.1（2026-09-28）—— 修 7 处，其中 6 处在 v1.0 上会让报告写错结论

| # | 症状 | 根因 | 影响 |
|---|---|---|---|
| 1 | 两个 `.ps1` 在中文 Windows 的 PS 5.1 下直接 ParserError | 存成了无 BOM 的 UTF-8（见上方编码契约） | 脚本在该环境**完全不可用** |
| 2 | 「语言分布」表语言名全空 | 读 `$e.Language`，而 scc 的 JSON 字段叫 `Name` | 报告里 13 行语言名全空 |
| 3 | 「体量最大的 N 个文件」整表空白 | scc 不加 `--by-file` 时 `Files` 数组恒为空 | 热点候选一条都给不出 |
| 4 | 变更热力表被 java 报错文本污染 | `-c git2` 解析器对本版 jar 不可用；且脚本把报错当 CSV 数据采信 | 报错文本被当"最频繁变更的文件"写进报告 |
| 5 | 「一级目录」表混进 `.git` / `dist` / `build` | 噪声正则要求尾随分隔符，根级目录漏网 | 模块切分候选被噪声占位 |
| 6 | 仓库里有 5 套测试却报「未检测到任何测试/构建配置 —— 从零开始造裁判」 | 只查根目录，不看子项目 | **把错误结论直接写进报告**，monorepo 尤甚 |
| 7 | 中文提交信息与脚本自身输出在管道/重定向下乱码 | PS 5.1 按控制台 OEM 代码页解码子进程输出、编码自身输出 | 报告中文不可读；`-Verify` 的回执给 agent 读是乱码，"证据是脚本输出"这条铁律落空 |

**怎么验的**：`hooks-ledger.ps1` 的 14 步生命周期（干净态 → 登记 → 未拆应拦 → 预演 → `-Apply` → 拆后应绿 → 扫描）在 PS 5.1 与 pwsh 7.6 下各跑一遍全对；`phase0-recon.ps1` 用**同一目标仓、同一解释器**跑 v1.0/v1.1 对照，第 2~7 项逐条翻正（如语言名空行 13→0、体量表 0→20 行、java 报错污染 3→0、噪声目录 build/dist/.git→无、测试设施"从零开始"→检出 5 处）。

### v1.0（2026-09-24）

首版：两条铁律、A→E 五步流程、钩子台账与强制拆除、侦察调度器。

## 来源与致谢

方法源自社区十年积累：**aim42**（Architecture Improvement Method）、Michael Feathers《Working Effectively with Legacy Code》、**Mikado Method**、Martin Fowler 的 *Patterns of Legacy Displacement*、Adam Tornhill 的软件分析、Markus Harrer 的 *awesome-legacy-systems*。

实证数据来自：SWE-Refactor（arXiv [2602.03712](https://arxiv.org/abs/2602.03712)）、RefAgent（arXiv [2511.03153](https://arxiv.org/abs/2511.03153)）、Codebase-Memory（arXiv [2603.27277](https://arxiv.org/abs/2603.27277)）。

## License

MIT
