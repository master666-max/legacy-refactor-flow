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
- 可选外部工具——**有则用，无则自动降级**：`scc` / `tokei` / `cloc`（语言统计）、`code-maat`（变更热力）、`jscpd`（重复率）

## 来源与致谢

方法源自社区十年积累：**aim42**（Architecture Improvement Method）、Michael Feathers《Working Effectively with Legacy Code》、**Mikado Method**、Martin Fowler 的 *Patterns of Legacy Displacement*、Adam Tornhill 的软件分析、Markus Harrer 的 *awesome-legacy-systems*。

实证数据来自：SWE-Refactor（arXiv [2602.03712](https://arxiv.org/abs/2602.03712)）、RefAgent（arXiv [2511.03153](https://arxiv.org/abs/2511.03153)）、Codebase-Memory（arXiv [2603.27277](https://arxiv.org/abs/2603.27277)）。

## License

MIT
