---
name: legacy-refactor-flow
description: 遗留系统/屎山重构的通用流程，自带强制拆除。当用户说「重构这个屎山」「这项目没人懂也没测试」「遗留代码怎么安全改造」「legacy 怎么现代化」，或面对一个只知大致用途、缺少测试、可能是 AI 生成的代码库需要安全改造时使用。流程：立界→测绘→定活→造裁判→小步改；全过程把创建的持久化钩子登记入台账，收尾时强制拆除并脚本验证，保证不留任何跨会话残留。
---

# 遗留系统重构通用流程 v1.0

## 0. 两条铁律

**铁律一：先造裁判，再动代码。**
重构的安全性上限 = 你能多快发现自己改坏了。没有裁判的改动不是重构，是赌博。
造裁判**不需要先看懂代码**——特征测试断言的是「现在就是这样」，不是「应该这样」。

**铁律二：用完必须拆干净。**
本 skill 不允许留下任何持续性钩子。会跨会话 / 跨进程 / 跨仓库继续生效的东西，收尾时必须清掉，并**用脚本验证**——不接受「我删过了」。

| | 例子 | 处置 |
|---|---|---|
| **成果物** | 侦察报告、特征测试、codemod 脚本、文档 | **默认保留**（用户要的就是这些） |
| **持续性钩子** | MCP 注册、git hook、CI 门、常驻索引/DB、daemon/watcher/cron、环境变量、后台任务、临时 worktree、被自动追加进 AGENTS.md / CLAUDE.md 的段落 | **必须拆除** |

## 1. 30 秒判断该不该用

1. 有可信的自动化测试吗？→ **有**：直接小步改，本 skill 只用到第 2 步的 E 和第 5 步。
2. 代码跑得起来吗？→ **跑不起来、也没人调用**：那是尸体，标删除日期即可，别重构。
3. 只是「代码丑」但改起来不害怕？→ 用普通重构工具，别上这套流程。

## 2. 流程：A → B → C → D → E

| 步 | 目标 | 关键动作 | 出口条件 |
|---|---|---|---|
| **A 立界** | 定义「改好了」 | 写 SCOPE（in-scope / read-only / DoD）；抓基线数字；`git tag v0-baseline` | 能一键 build + 能本地 run |
| **B 测绘** | 拿结构事实，不靠人读 | 用图谱/依赖工具回答三件事：谁 import 谁、公共接口面、**被调用最多的 10 个函数** | 依赖图能画出，环形依赖清单产出 |
| **C 定活** | 先减量，这是最大杠杆 | 用生产日志 / 覆盖率 / 入口点反推，给每个入口点打 **LIVE / DEAD / UNKNOWN** | 每个入口点都有判定 |
| **D 造裁判** | 造出「变化探测器」 | 边界特征测试（**期望值来自真实运行**）；外部依赖用录制回放；**故意改坏验证测试会红** | `make test` 跑得起来 |
| **E 小步改** | 确定性改造 | 一个 PR 一个意图；大范围机械改动 → 让 AI 写 codemod、用确定性工具施加，**不让 AI 手改几百个文件** | 每步 diff 小且测试绿 |

A~D 是纯投入期，**一行业务代码都不改**。跳过 D 直接进 E，就是失败率约 60% 的那批样本。

### 2.1 三条来自实证的约束（它们决定了流程的形状）

- **复合重构是主要失败源**：SWE-Refactor（arXiv 2602.03712）中 Codex 在复合重构上成功率仅 **39.4%** → 任务必须拆到单意图。
- **图谱省 token，但不提高准确率**：Codebase-Memory（arXiv 2603.27277）83% vs 文件探索 92%，但省 **10× token** → 结构问题查图，「这段实现到底干嘛」必须读文件。
- **有效形态是多 agent + 测试回路**：RefAgent（arXiv 2511.03153）单测通过率中位数 90%，比单 agent 高 **64.7%** → 写代码的和验证的不能共用同一个上下文。

## 3. ★ 钩子台账（贯穿全程，创建即登记）

**任何持续性钩子，在创建的同一刻写进台账。** 不要「回头想想加了什么」——那时候你一定漏。

台账由 `scripts/hooks-ledger.ps1` 维护：

```powershell
# 创建钩子前，先把原文件备份出来
Copy-Item <原文件> <备份路径> -Force

# 登记（Action 三选一：created / modified / appended）
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Register -Kind config -Path <钩子路径> -Action modified -Backup <备份路径>
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Register -Kind dir -Path <新建目录> -Action created
```

- `created` —— 原来不存在，拆除 = 删除
- `modified` / `appended` —— 原来存在被改写或追加，拆除 = 从备份恢复

**默认不装钩子。** 优先用只读、一次性、可丢弃的方式。确实需要装时，先确认它可被一键拆掉，再装。

## 4. ★ 拆除（收尾必做，不可跳过）

```powershell
# 1) 预演：列出将要删除 / 恢复的东西（不执行）
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Teardown

# 2) 确认无误后执行
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Teardown -Apply

# 3) 验证：逐条核对，任一未清干净即返回非零退出码
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Verify

# 4) 通用扫描：不依赖台账，查常见残留物
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Sweep -Repo <目标仓库>
```

**拆除完成前不要宣布任务结束。** 交付时必须写清三件事：保留了什么（成果物路径）、拆除了什么、验证输出是什么。

### 4.1 高频残留物清单（照着核）

- [ ] `.mcp.json` / `mcp.json` / `settings.json` 里的 server 注册
- [ ] `.git/hooks/` 下除 `.sample` 之外的任何文件
- [ ] CI 配置（`.github/workflows/*`、`.gitlab-ci.yml`）
- [ ] `AGENTS.md` / `CLAUDE.md` / `.cursorrules` 被自动追加的段落
- [ ] 常驻索引或数据库（`.codebase-memory/`、向量库、缓存目录）
- [ ] daemon / watcher / cron 条目
- [ ] 环境变量与 shell profile 改动
- [ ] 后台任务、临时 worktree、临时目录、临时端口

## 5. 工具：有则用，无则降级——别自己写分析脚本

| 目的 | 首选现成工具 | 降级 |
|---|---|---|
| 语言 / 体量统计 | `scc` > `tokei` > `cloc` | 脚本内置兜底 |
| 变更热力 / 热点 | `code-maat` > `hercules` | `git log --name-only` |
| 结构查询（谁调用谁） | 图谱 MCP（codebase-memory-mcp） / `Serena`(LSP) | `ast-grep` / `ripgrep` |
| 模块边界检查 | ArchUnit / import-linter / dependency-cruiser | 手写断言 |
| 变异测试（验证裁判有效） | Stryker / PIT / mutmut / cargo-mutants | 手动「故意改坏」 |
| 重复代码 | `jscpd` / SonarQube CE | — |
| 确定性批量改造 | `ast-grep` / OpenRewrite / jscodeshift / libcst / Rector | — |

`scripts/phase0-recon.ps1` 本身就是这些工具的**调度器**：优先调 scc/tokei/cloc/code-maat，内置实现仅兜底，并在报告里标注数据来源。

### 5.1 社区已有的方法，不要重新发明

- **aim42 · Architecture Improvement Method**（Analyze → Evaluate → Improve）——本流程的上位框架
- **Mikado Method** ——改到一半发现动不了时的标准处理：只回滚、不硬闯，把依赖记成图
- **Strangler Fig / Patterns of Legacy Displacement** ——不能原地改时的替换模式
- **Zones（绿/黄/红风险分区）** ——与 C 步的死活分类互补，建议合并成二维分诊

详见 `references/COMMUNITY-MAP.md`；完整操作手册见 `references/REFACTOR-RUNBOOK.md`。

## 6. 结束前自检

1. `hooks-ledger -Verify` 是不是全绿？
2. 目标仓库 `git status` 里剩下的，是不是都是用户要的成果物？
3. 我有没有把「我删过了」当成证据？（证据应该是脚本输出，不是记忆）
4. 报告里有没有标清楚：哪些数字来自真实运行，哪些是 AI 的推测？
