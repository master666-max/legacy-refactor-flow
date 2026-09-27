---
name: legacy-refactor-flow
description: 遗留系统/屎山重构的通用流程，自带强制拆除。当用户说「重构这个屎山」「这项目没人懂也没测试」「遗留代码怎么安全改造」「legacy 怎么现代化」，或面对一个只知大致用途、缺少测试、可能是 AI 生成的代码库需要安全改造时使用。流程：立界→测绘→定活→造裁判→小步改；全过程把创建的持久化钩子登记入台账，收尾时强制拆除并脚本验证，保证不留任何跨会话残留。
---

# 遗留系统重构通用流程 v1.3

## 0. 两条铁律

**铁律一：先造裁判，再动代码。**
重构的安全性上限 = 你能多快发现自己改坏了。没有裁判的改动不是重构，是赌博。
造裁判**不需要先看懂代码**——特征测试断言的是「现在就是这样」，不是「应该这样」。
但**造了 ≠ 够强**：裁判的强度是一个数（变异得分 killed/total），不是一个动作；D 步要求把它报出来。

**铁律二：用完必须拆干净。**
本 skill 不允许留下任何持续性钩子。会跨会话 / 跨进程 / 跨仓库继续生效的东西，收尾时必须清掉，并**用脚本验证**——不接受「我删过了」。
登记时给租约（`-TTLHours`），拆不完的部分交给**收集器**而不是交给"我还活着"：发起方半路死了，`-Collect` 也能收（见 §3.1）。

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
| **C 定活** | 先减量，这是最大杠杆 | 用生产日志 / 覆盖率 / 入口点反推，给每个入口点打 **LIVE / DEAD / UNKNOWN** | 每个入口点都有 `(判定, 观测窗口, 触达画像)` 三元组；DEAD 的删除动作**可撤回**（留分支/留 flag，不 `rm`） |
| **D 造裁判** | 造出「变化探测器」 | 边界特征测试（**期望值来自真实运行**）；外部依赖用录制回放；用 `scripts/mutation-probe.ps1` 注变异量出**得分**（不是"故意改坏一次"） | `make test` 跑得起来 **且** 报出变异得分与被改动文件上的 killed/total；**任何与基线的行为差异一律登记，含你认为"顺手修对了"的** |
| **E 小步改** | 确定性改造 | 一个 PR 一个意图；大范围机械改动 → 让 AI 写 codemod、用确定性工具施加，**不让 AI 手改几百个文件** | 每步 diff 小且测试绿 |

A~D 是纯投入期，**一行业务代码都不改**。跳过 D 直接进 E，等于在没有探测器的情况下改代码——
下面那 39.4% 是**模型在基准上的成绩**，不是"跳过裁判的重构有多少会砸"的测量，只能当类比，别当证据。

**C 步为什么要有窗口**：静态可达性判 DEAD 在反射 / DI / 序列化 / 配置装类上必然崩，而日志反推是
"缺证据当反证据"——季度批处理与灾备路径在 90 天窗口里都长得像死的。所以 DEAD 不是标签，是**带观测窗口的概率**。

**D 步为什么要报得分**：造了裁判 ≠ 裁判抓得住改动。特征测试是对"等价"做**抽样**，
抽样强度是一个数（killed/total），不是一个动作。只"故意改坏一次"等于 n=1 的注错，
证明的是这套测试对这个特定变异非空，对其他一切变异没说过任何东西。

### 2.1 四条来自实证的约束（它们决定了流程的形状）

- **复合重构是主要失败源**：SWE-Refactor（arXiv 2602.03712）中 OpenAI Codex 在 compound 实例上成功率仅 **39.4%**
  （基准共 1,099 题 = 922 atomic + **177 compound**，18 个 Java 仓）→ 任务必须拆到单意图。
  注意反面：拆到单意图会让每个 PR 都绿，**跨单元一致性**却没人管——那要靠 E 步的"每步测试绿"+ 整体回归兜。
- **图谱省 token，但不提高准确率**：Codebase-Memory（arXiv 2603.27277）答案质量 83% vs 文件探索 92%，代价省 **10× token**（31 个真实仓）
  → 结构问题查图，「这段实现到底干嘛」必须读文件。**这条分工的分类器是你自己**：
  拿不准这题算不算"结构问题"时，**弃权退回读文件**；把图的答案当引用是最省 token、最亏的一次交易。
- **有效形态是多 agent + 测试回路**：RefAgent（arXiv 2511.03153）单测通过率中位数 90%，比单 agent 基线**相对**高 **64.7%**（8 个 Apache Java 仓）
  → 写代码的和验证的不能共用同一个上下文。（64.7% 是相对提升，不是 64.7 个百分点。）
- **手上那套测试是弱 oracle**：Foundation Models as Oracles（arXiv 2605.02096，226 个真实历史缺陷案例）原话是
  "developers' test suites are insufficient, as they do not adequately exercise many refactored methods and fields"；
  其模型首跑 93.8%／累计 97.3%。⇒ 别把"我的测试跑绿了"当等价性的全部证据。
  **但别照搬**：那是分类准确率，模型非确定性一旦进闸门，同一份代码两次跑出门不同——审计语境里这是另一类恒真风险。
  本 skill 的立场：「AI 提假设、运行来裁决」这条不动摇，模型不许手写期望值；模型可以当**补漏的第二个探测器**，
  但它的结论必须被运行证据复核之后才能入账。

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

### 3.1 租约：让"拆干净"不依赖发起方活着

台账是写前日志（WAL + undo）。它有一个数据库早就解决、而这里没解决的问题：**拆除动作挂在发起方身上**。
会话被切断、子代理变孤儿（本机 AGENTS.md R-4 记过这事）⇒ 台账里写着"待拆"，但没人再来读它。
解法不是"记得拆"，是**授权会过期 + 外部清扫者**：

```powershell
# 登记时给存活小时数：条目带上 owner/expires
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Register -Kind dir -Path <目录> -Action created -Owner <会话号> -TTLHours 6
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Renew -Owner <会话号> -TTLHours 6     # 还没干完就续命
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Collect                                # 干跑：只报过期孤儿
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Collect -Apply                          # 真拆
```

三条规矩，缺一不可：
- **`-Collect` 默认干跑**。列完孤儿要你加 `-Apply` 才动手——自动删东西不留第二次机会，是这套流程不该有的奢侈。
- **没有 `expires` 的条目永远不算孤儿**。"没登记到期时间" ≠ "已到期"；误删比漏删严重得多，所以收集器宁可留残留。
- **缺备份的一律不动**（返回非零并指名道姓）。恢复不了的条目交给人类，不交给启发式。

`-Verify` 会顺手报 `EXPIRED=n`：全绿但有 n 条租约过期未拆 ⇒ 那是收集器的活，不是你的活，但**必须在交付里写出来**。

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

#    -Strict：连"[?] 可能是用户本来就有的东西"也判失败，逼你逐项确认完
./scripts/hooks-ledger.ps1 -Ledger _refactor-kit/hooks.json -Sweep -Strict -Repo <目标仓库>
```

`-Verify` 与 `-Sweep` 收尾各打一行 ASCII 计数（`BAD=/OK=`、`HARD=/CHECK=/UNCOVERED=`）给上层程序读；
`UNCOVERED` 那几类是**本工具判不了的**，看见它就得当人工的，不许当成"扫过了"。

**拆除完成前不要宣布任务结束。** 交付时必须写清三件事：保留了什么（成果物路径）、拆除了什么、验证输出是什么。

### 4.1 高频残留物清单（照着核）

标 ✅ 的 `-Sweep` 会自动查（算 `[X]` 硬残留或 `[?]` 待确认）；标 ✋ 的它判不了，得人工过一遍。

- [ ] ✅ `.mcp.json` / `mcp.json` / `settings.json` 里的 server 注册 `[?]`
- [ ] ✅ `.git/hooks/` 下除 `.sample` 之外的任何文件 `[X]`
- [ ] ✅ `core.hooksPath` 被改指到仓外 `[X]`（只看 `.git/hooks` 目录会整个漏掉这一类）
- [ ] ✅ 临时 worktree（`git worktree list` 多于一个）`[X]`
- [ ] ✅ CI 配置（`.github/workflows/*`、`.gitlab-ci.yml`、`azure-pipelines.yml`、`.circleci`、`Jenkinsfile`…）`[?]`
- [ ] ✅ `AGENTS.md` / `CLAUDE.md` / `.cursorrules` 被自动追加的段落 `[?]`
- [ ] ✅ 环境变量文件 `.env` / `.env.local` / `.envrc` `[?]`
- [ ] ✅ 常驻索引或数据库（`.codebase-memory/`、`.serena/`、`.repomap/`、向量库、缓存目录）`[?]`
- [ ] ✅ 目标仓库 `git status` 的剩余变更 `[?]`
- [ ] ✋ daemon / watcher 进程
- [ ] ✋ crontab 与 Windows 计划任务
- [ ] ✋ 用户级环境变量与 shell profile 改动（在仓外，`-Sweep` 只扫 `-Repo` 一个目录）
- [ ] ✋ 常驻端口、后台任务、临时 worktree 之外的临时目录
- [ ] ✋ 跨仓写入（本流程若动过别的仓，得逐仓扫）

## 5. 工具：有则用，无则降级——别自己写分析脚本

| 目的 | 首选现成工具 | 降级 |
|---|---|---|
| 语言 / 体量统计 | `scc` > `tokei` > `cloc` | 脚本内置兜底 |
| 变更热力 / 热点 | `code-maat` > `hercules` | `git log --name-only` |
| 结构查询（谁调用谁） | 图谱 MCP（codebase-memory-mcp） / `Serena`(LSP) | `ast-grep` / `ripgrep` |
| 模块边界检查 | ArchUnit / import-linter / dependency-cruiser | 手写断言 |
| 变异测试（验证裁判有效） | Stryker / PIT / mutmut / cargo-mutants | `scripts/mutation-probe.ps1`（内置文本级兜底，给下限证据） |
| 重复代码 | `jscpd` / SonarQube CE | — |
| 确定性批量改造 | `ast-grep` / OpenRewrite / jscodeshift / libcst / Rector | — |

`scripts/phase0-recon.ps1` 本身就是这些工具的**调度器**：优先调 scc/tokei/cloc/code-maat，内置实现仅兜底，并在报告里标注数据来源。

D 步用 `scripts/mutation-probe.ps1` 量裁判强度——它往代码里注入语义变异（比较符、边界、布尔），
每注一个就跑一遍测试：**测试红了说明裁判看得见，测试还绿说明这一类改动没人报警**。

```powershell
./scripts/mutation-probe.ps1 -Repo D:\path\to\repo -TestCmd "make test" -Targets src -OutFile mutation-report.md
```

三条它自己写在报告里的老实话：**基线是红就拒跑**（这时候任何"抓住了"都是假信号）；全程只动 `%TEMP%` 副本，
一行业务代码不会被真改；得分是**下限证据**不是充分性证明——等价变异体没剔除、没被任何测试触达的代码必然显示为漏放。

改这两个脚本前先看 README「编码契约」：`.ps1` 必须存成**带 BOM 的 UTF-8**，且保留脚本开头的 `[Console]::OutputEncoding = UTF8`。少一条，脚本在「中文 Windows + PowerShell 5.1」这个默认组合上要么直接 ParserError 不可用，要么输出经管道给上层时中文整片乱码——而这套流程的收尾判定恰恰依赖读脚本输出。

### 5.1 社区已有的方法，不要重新发明

- **aim42 · Architecture Improvement Method**（Analyze → Evaluate → Improve）——本流程的上位框架
- **Mikado Method** ——改到一半发现动不了时的标准处理：只回滚、不硬闯，把依赖记成图
- **Strangler Fig / Patterns of Legacy Displacement** ——不能原地改时的替换模式
- **Zones（绿/黄/红风险分区）** ——与 C 步的死活分类互补，建议合并成二维分诊

详见 `references/COMMUNITY-MAP.md`；完整操作手册见 `references/REFACTOR-RUNBOOK.md`。

## 6. 结束前自检

1. `hooks-ledger -Verify` 是不是全绿？`-Sweep` 是不是 `HARD=0`？
2. 目标仓库 `git status` 里剩下的，是不是都是用户要的成果物？
3. 我有没有把「我删过了」当成证据？（证据应该是脚本输出，不是记忆）
4. 报告里有没有标清楚：哪些数字来自真实运行，哪些是 AI 的推测？
5. `-Sweep` 打的 `UNCOVERED=` 那几类（daemon / crontab / 用户级环境变量 / 常驻端口 / 跨仓），我人工过了吗？没过的必须在交付里写明「未核」，不许沉默地当 0。
6. **裁判得分报了吗？** `MUT score=… killed=… total=…`。没跑探针就得写"裁判强度未知"，而不是暗示"测试全绿=安全"。
7. **每一条与基线的行为差异都登记了吗？** 包括你认为"本来就该改对"的那一条——值中性是特征测试的全部意义，
   一旦允许 agent 自行判定"这个差异是修 bug"，测试集就变成反对变化的那一方。
8. 有没有钩子带着已过期的租约还活着（`EXPIRED>0`）？发起方已经不在的话，`-Collect` 跑过没有？
