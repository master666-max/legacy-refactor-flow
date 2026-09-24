# 屎山重构作战手册 v1

> 适用场景：**只清楚项目大致用途**、没有可信测试、代码大概率是 AI 生成的遗留系统（legacy / brownfield）。
> 本手册的每一条流程都对应 2026 年的实证结果，不是经验之谈的堆砌。文末附证据来源。

---

## 0. 先接受四条实证结论（它们决定了流程的形状）

| # | 结论 | 证据 | 对流程的约束 |
|---|---|---|---|
| 1 | LLM 擅长**原子**重构，不擅长**复合**重构 | SWE-Refactor（1,099 个真实重构，18 个 Java 项目，9 个模型）：Codex agent 在复合重构上**只有 39.4% 成功率** | 所有任务必须拆成单意图的小步，禁止"顺手把这块也整理了" |
| 2 | 有效形态是**多 agent + 测试回路**，不是单 agent | RefAgent（多 agent 规划/执行/测试/自省）：单测通过率中位数 90%，代码坏味道降 52.5%；**比单 agent 的单测通过率高 64.7%** | 必须有独立的"验证"角色，且它不参与写代码 |
| 3 | 代码图谱**省 token，但不提高准确率** | Codebase-Memory（66 语言，31 仓）：83% 质量 vs 文件探索的 92%，但 **1/10 token、1/2.1 工具调用** | 图谱用来问"谁调用谁/影响面"；"这段实现到底在干嘛"必须回退到读文件 |
| 4 | 最优混合模式：**让 AI 写改造脚本，再用确定性工具执行** | Markus Harrer（iSAQB）：hybrid AI —— agent 生成 refactoring script，人用代码变换工具确定性地施加 | 大范围机械改动永远走 codemod，不让 AI 直接手改文件 |

**由此推出的三条铁律：**

1. **没有裁判不动手。** 重构的安全性上限 = 你能多快发现自己改坏了。造裁判优先于改代码。
2. **先减量，再重构。** 删掉不需要理解的代码，是零风险、最高杠杆的一步。真屎山里常有 40%~70% 是死代码或从未被走到的分支。
3. **AI 提出假设，运行负责裁决。** 永远不让模型凭"理解"手写测试期望值。

---

## 1. 七阶段总览

| 阶段 | 目的 | 产物 | 出口条件（不满足不许进下一阶段） | 预估 |
|---|---|---|---|---|
| **P0 立界** | 定义成功、冻结范围、抓基线 | `SCOPE.md` + 基线数字 | 能一键 build + 能本地 run | 0.5 天 |
| **P1 测绘** | 用工具产出结构化事实，不靠人读 | `MAP.md` + 依赖图 + 环清单 | 依赖图能画出；环形依赖清单产出 | 1~2 天 |
| **P2 定活** | 分清 LIVE / DEAD / UNKNOWN，先删 | `LIVE.md`（要保护的接口面） | 每个入口点都有 LIVE/DEAD 判定 | 1~3 天 |
| **P3 造裁判** | 造出"变化探测器" | 特征测试 + 契约测试 + 回放 | `make test` 可跑；mutation score ≥ 40% | 3~10 天 |
| **P4 定规则** | 防回流，让坏架构会红 | 架构适应度函数进 CI | 故意跨层调用 → CI 必须红 | 0.5 天 |
| **P5 小步重构** | 原子化 + 确定性改造 | 一连串小 PR | 每个 diff < 400 行且测试绿 | 持续 |
| **P6 绞杀替换** | 换不掉的就绕开长 | facade + flag + 影子流量 | 新实现接管流量，旧的标删除日期 | 持续 |
| **P7 固化记忆** | 让认知不随会话归零 | 更新 `AGENTS.md` + ADR + 重跑图谱 | 结构指标单调不劣化 | 每阶段末 |

> 关键：**P0~P4 是纯投入期，一行业务代码都不改。** 心急跳过 P3 直接进 P5，就是那 60.6% 的失败样本。

---

## 2. 逐阶段操作

### P0 · 立界（半天）

目标不是理解代码，是**造一个不会退化的地基**。

```powershell
# 0.1 先确认它现在是什么状态
git log --oneline -20                 # 有没有历史、有没有 AI 批量提交的痕迹
git tag v0-baseline                   # 打一个不可变的起点，任何实验都能回滚
```

写 `SCOPE.md`，只填四项：

```markdown
## 项目目的（一句话）
<你唯一知道的那件事>

## in-scope
- src/xxx/**

## out-of-scope（本轮绝不碰）
- 任何第三方 vendored 代码、生成物、legacy/ 目录

## 完成定义（DoD）
- 例：环依赖 = 0；入口点各有 ≥5 条特征测试；CI 全绿；旧 facade 下线
```

**抓基线数字**（没有基线就无法证明重构有价值，也无法向任何人交差）：

| 基线项 | 怎么量 | 记录值 |
|---|---|---|
| 文件数 / 总行数 | 见 `phase0-recon.ps1` | |
| 构建耗时 / 启动耗时 | `time make build` | |
| 测试数（当前可能是 0） | CI 输出 | |
| 环形依赖数 | P1 产出 | |

> ⚠️ 翻车点：把"重构"定义成"变好看"。必须定义成**可测量的结构指标**（见 §5）。

---

### P1 · 测绘（1~2 天）

**这一阶段你自己不读代码，你只让工具产出事实。** AI 的角色是归纳与解释，不是事实来源。

按你要回答的问题选工具（这是 Ry Walker 那份 17 工具对比的核心结论：**先选检索任务，再选工具**）：

| 你要问的问题 | 该用的工具类别 | 具体工具 |
|---|---|---|
| 谁调用谁、传递依赖、影响面 | **代码图谱（tree-sitter → 图）** | `codebase-memory-mcp`（66 语言，14 个查询工具，MCP） |
| 跨文件重命名、找引用、精确跳转 | **LSP / 符号级** | `Serena`（MCP；注意当前应用层是 GPL） |
| "全库骨架，塞进 token 预算" | **Repo Map** | Aider 内置 repo map、`RepoMapper` |
| 结构化的批量搜索/改写 | **AST 模式匹配** | `ast-grep`（多语言）、`semgrep`、`GritQL` |
| 模块边界有没有被破坏 | **依赖规则检查** | `dependency-cruiser`(JS/TS)、`import-linter`(Py)、`ArchUnit`(Java)、`deptrac`(PHP) |
| 重复代码 | **克隆检测** | `jscpd`（多语言） |
| 哪些代码根本没人用 | **死代码检测** | `knip`(JS/TS)、`vulture`(Py) |

**跑一遍侦察脚本**（本套件自带，先拿到骨架数据）：

```powershell
./phase0-recon.ps1 -RepoPath D:\path\to\repo -OutFile recon-report.md
```

**产出 `MAP.md`，回答三个问题：**
1. 模块依赖清单 —— 谁 import 谁，**环形依赖在哪**（环是重构的第一优先级，因为它是"改 A 坏 B"的物理原因）
2. 公共接口面 —— 每个对外函数/端点的签名 + **调用者数量**
3. 风险热点 —— **被调用最多的 10 个函数**（动它们 = 全库回归）

> ⚠️ 翻车点：让 AI"生成整个代码库的文档"。iSAQB 记录的真实案例是：某厂商用 agent 为一段 **100 行 COBOL 生成了近 30 页 PDF**，没人会去校验，更没人会维护它。**文档只在有人会读它时才存在。**

---

### P2 · 定活（1~3 天）—— 杠杆最大的一步

方法：**从运行时的证据反推，而不是从代码反推。**

按优先级尝试：
1. **生产日志 / APM / OpenTelemetry** —— 最诚实的文档。
2. **覆盖率工具跑一遍真实场景**：`coverage.py`、`c8`/`istanbul`、`JaCoCo`、`go test -cover`。
3. **入口点枚举** —— `main.*`、`index.*`、CLI、HTTP 路由表、cron、消息消费者。
4. 什么都没有？**那就给入口点加日志，跑一周**。这一周的等待比三个月的盲改便宜。

给每个入口点打标签：

| 标签 | 判据 | 动作 |
|---|---|---|
| **LIVE** | 近 90 天有真实流量/执行 | 进 P3 造裁判，它是保护对象 |
| **DEAD** | 无任何调用方 + 无流量 | **冻结 + 标删除日期**，不重构 |
| **UNKNOWN** | 无法判定 | 排期探测，不进本轮重构 |

> ⚠️ 翻车点：对尸体做心肺复苏。跑不起来又没人调用的代码，问题不是"烂"，是"已经死了"。

---

### P3 · 造裁判（3~10 天，可并行）—— 全流程的翻盘点

你需要两种测试，绝大多数人把它们混为一谈：

- **规格测试**：断言"应该怎样"。**在真屎山里写不出来**，因为你不知道。
- **特征测试（characterization test / approval test / golden master）**：断言"现在就是这样"。**不需要你懂代码。**

**P3 只做第二种。**

#### 三条腿

| 腿 | 解决什么 | 工具 |
|---|---|---|
| **特征测试** | 模块边界的输入→输出快照 | ApprovalTests（多语言）、`syrupy`/`pytest-snapshot`(Py)、Vitest/Jest snapshot、`.approved.txt` |
| **契约测试** | 对外 API/消息格式不许变 | Pact、JSON Schema 快照 |
| **记录-回放** | 外部依赖（DB/HTTP/队列）不可控 | `VCR.py`、`Polly.js`/`nock`、`WireMock`、`Testcontainers`、`go-vcr` |

#### 硬规则（违反则整套流程失效）

> **期望值必须来自真实运行，绝不能来自模型的理解。**
> 让 AI 手写"我认为应该返回 X"——那是幻觉测试，它把 bug 一起"验证"成了正确行为，而且你永远不会发现。

正确姿势：
1. 给 AI 一段边界代码，让它输出 **"我认为的行为 + 置信度（高/中/低）+ 需要什么实验才能验证"**。
2. 你照着"需要什么实验"去写探针，**跑出真实结果**。
3. 把真实结果录成 approval 快照。**置信度为"低"的地方，测试名里标 `TODO-可疑`。**
4. bug 一起冻结。先钉住现状，再决定要不要改变现状。

#### 验证裁判真的有效（这一步不能省）

```bash
# 故意改坏一个不重要的函数
# 如果测试还是绿的 —— 那不是测试，是装饰品
```

用 **mutation testing** 系统化地做这件事：`mutmut`/`cosmic-ray`(Py)、`Stryker`(JS/TS/C#)、`PIT`(Java)、`cargo-mutants`(Rust)。

**出口门槛（先定低，别追求完美）**：
- `make test` 一条命令能跑 ✅
- 每个 LIVE 入口点至少 5 条来自真实数据的样本 ✅
- mutation score ≥ 40%（这个数字就能挡住绝大多数"改 A 坏 B"）✅

---

### P4 · 定规则（半天）

把架构约束写成**会红的测试**，而不是写在 wiki 里：

| 语言 | 工具 | 典型规则 |
|---|---|---|
| Java/Kotlin | ArchUnit | 分层依赖、禁止循环 |
| JS/TS | dependency-cruiser | 禁止跨层 import |
| Python | import-linter | 禁止 domain → infra |
| PHP | deptrac | 层边界 |

进 CI。**这一阶段之后，AI 就算犯错也撞不穿墙。**

---

### P5 · 小步重构（持续）

这是唯一"真正在改代码"的阶段，它的形状由 §0 结论 1 和 4 决定。

#### 5.1 每步必须原子

来自 SWE-Refactor 的硬数据：**复合重构是失败的主要来源（39.4%）**。所以：

- 一个 PR = **一个意图**（提取函数 / 改一个命名 / 换一个依赖）
- 一个 PR 只动**一个边界清晰的模块**
- diff < 400 行为目标
- 测试绿 + 立即 commit（这一步的 commit 就是你的 undo）
- 用 git worktree 隔离并行任务，避免多个 agent 互相踩

#### 5.2 大范围改动走 codemod，不走 AI 手改

**这是最重要的一条。** 让 AI 写**改造脚本**，然后用确定性工具施加：

| 语言 | 确定性改造工具 |
|---|---|
| 多语言 | `ast-grep`（AST 模式匹配 + 批量改写）、`semgrep --autofix`、GritQL |
| Java | **OpenRewrite**（recipes）/ Moderne |
| JS/TS | `jscodeshift`、`ts-morph` |
| Python | `libcst`、`bowler` |
| PHP | **Rector** |
| C# | Roslyn analyzers/codefixes |
| Go | `gofmt`/`go/ast` + `gopls` rename |

**为什么这条关键**：AI 手改 200 个文件 = 200 次随机采样，每次都独立可能出错；AI 写一个 codemod = 1 次生成 + N 次**可审计、可重放、可 diff**的机械施加。前者是概率，后者是确定性。

#### 5.3 提示词模板 · 写 codemod

```text
不要直接修改任何文件。
任务：把 [模式 A] 改写成 [模式 B]。
1) 先用 ast-grep 的 pattern 语法写出匹配规则，并给出它能匹配到的文件数
2) 拿 3 个真实文件做样例，展示 before/after 的精确 diff
3) 给出边界情况：哪些写法**不会**被匹配、哪些会被误匹配
4) 写成脚本，我先在 3 个文件上验证，确认后再全库施加
```

---

### P6 · 绞杀替换（持续）

对**不能原地改**的部分（正在跑、没有裁判、改动风险高），不要重写，**绕开长**。

Strangler Fig 的标准三步：
1. **Facade**：新代码只走新接口，旧内脏一行不改 —— 见效最快、风险最低。
2. **Feature flag**：OpenFeature / Unleash / Flagsmith，新旧并行，可一键回退。
3. **影子流量**：新实现先接收镜像流量、只记录不返回，比对差异；一致后再切主流量。

原地重写 = 用未知换未知；绞杀 = 用已知逐步替换未知。

---

### P7 · 固化记忆（每阶段末）

- 更新 `AGENTS.md` / `CLAUDE.md`：in-scope、read-only、当前约定、常用命令
- 记录 ADR（决策记录）：**为什么这么改**，比"改了什么"更保值
- **重跑 P1 的图谱**，让它跟上代码
- 每完成一个模块，把"新约定"写回去 —— 形成正反馈

> ⚠️ 翻车点：记忆文件过期。过期的 CLAUDE.md 比没有 CLAUDE.md 更糟，因为它会主动误导。

---

## 3. 工具矩阵：按语言选

| 语言 | 图谱/符号 | 确定性改造 | 边界检查 | 变异测试 | 快照测试 |
|---|---|---|---|---|---|
| **通用** | codebase-memory-mcp, Serena, RepoMapper | ast-grep, semgrep, GritQL | — | — | ApprovalTests |
| **Python** | Serena, codebase-memory | libcst, bowler | import-linter | mutmut, cosmic-ray | syrupy, pytest-snapshot |
| **JS/TS** | Serena, codebase-memory | jscodeshift, ts-morph | dependency-cruiser | Stryker | Vitest/Jest snapshot |
| **Java/Kotlin** | Serena, codebase-memory | OpenRewrite | ArchUnit | PIT | ApprovalTests |
| **Go** | gopls, codebase-memory | go/ast, gofmt | — | go-mutesting | golden files |
| **Rust** | rust-analyzer | syn | — | cargo-mutants | insta |
| **PHP** | — | Rector | deptrac | — | — |
| **C#** | — | Roslyn | — | Stryker.NET | ApprovalTests.Net |

**通用前置**：`ripgrep`（搜索）、`tree-sitter`（解析底座）、`jscpd`（重复率）、`git`（安全网）。

**MCP 图谱选型建议**：
- 首次尝试 → `codebase-memory-mcp`（开箱即用、语言覆盖广、查询工具成体系）
- 需要精确类型/跨文件重命名 → 加 `Serena`（注意许可证：应用层 GPL）
- 只想要骨架 → Aider repo map 或 RepoMapper（最轻）
- ⚠️ 本地索引 ≠ 私有：还要查嵌入服务、托管索引、遥测、以及接收检索结果的 agent 这几条独立的数据通路。

---

## 4. 度量：怎么证明"变好了"

重构必须在数字上单调改善，否则就是在做风格迁移。

| 指标 | 工具 | 方向 | 起点 | 目标 |
|---|---|---|---|---|
| 环形依赖数 | ArchUnit / dependency-cruiser / madge | ↓ | | **0** |
| 重复率 | jscpd | ↓ | | −50% |
| 最大函数行数 | ast-grep 查询 | ↓ | | < 80 |
| mutation score | mutmut / Stryker / PIT | ↑ | 0 | > 60% |
| LIVE 入口点的快照测试数 | 测试框架 | ↑ | 0 | 全覆盖 |
| 单次改动所需工具调用数 | agent 日志 | ↓ | | −50% |
| 回滚率 | git | ↓ | | — |

**别只看省了多少 token**：Ry Walker 那份对比提醒得很对 —— **少用工具调用可能只是把更多源码留在上下文里，总成本反而更高。要同时量答案质量和整个会话的成本。**

---

## 5. 六个已知的坑

1. **让 AI 直接大改** → 复合重构失败率 60.6%。对策：原子化 + codemod。
2. **AI 手写测试期望值** → 幻觉测试，把 bug 固化成"正确行为"。对策：期望值只来自真实运行。
3. **用图谱替代读代码** → 图谱质量 83% < 文件探索 92%。对策：结构性问题查图，语义问题读文件。
4. **让 AI 生成海量文档** → 100 行代码 30 页 PDF，没人校验没人维护。对策：文档只在有读者时才写。
5. **无出口条件的开放式重构** → 永远做不完。对策：每阶段有硬门槛，达标即停。
6. **半途 token 爆炸** → agent 越拖越笨、开始重复自己。对策：开新会话 + 加载 `AGENTS.md` + 重跑图谱，而不是硬续。

---

## 6. 第一个 48 小时怎么过（照做版）

**Day 1 上午 —— 立界**
- [ ] `git tag v0-baseline`
- [ ] 写 `SCOPE.md`（in-scope / out-of-scope / DoD）
- [ ] 跑 `./phase0-recon.ps1 -RepoPath <你的仓库>`，把基线数字填进手册
- [ ] 确认能 build、能 run

**Day 1 下午 —— 测绘**
- [ ] 装一个图谱 MCP（推荐 codebase-memory-mcp），跑完全库索引
- [ ] 用图谱查询：环形依赖、被调用最多的 10 个函数、模块边界
- [ ] 产出 `MAP.md`（依赖清单 / 接口面 / 风险热点）
- [ ] 装 `ast-grep` + `jscpd`，拿到重复率基线

**Day 2 上午 —— 定活**
- [ ] 枚举入口点
- [ ] 有生产日志 → 直接分类；没有 → 加日志 + 定一周观察期
- [ ] 产出 `LIVE.md`，DEAD 清单打上删除日期

**Day 2 下午 —— 开第一口**
- [ ] 挑**最小**的一个 LIVE 模块
- [ ] 写 3~5 条**来自真实运行**的特征测试
- [ ] **故意改坏它，确认测试会红**
- [ ] 现在，你才允许改第一行代码

---

## 7. 证据来源

- **SWE-Refactor**（2026-02）：仓库级 LLM 重构基准，1,099 个真实重构 / 18 个 Java 项目 / 9 个模型，复合重构成功率 39.4% —— https://arxiv.org/abs/2602.03712
- **RefAgent**（2025-11）：多 agent 端到端重构框架，单测通过率中位数 90%，较单 agent +64.7% —— https://arxiv.org/abs/2511.03153
- **Codebase-Memory**（2026-03）：tree-sitter 知识图谱 + MCP，66 语言 / 31 仓，83% vs 92% 质量、10× 更少 token、2.1× 更少工具调用 —— https://arxiv.org/abs/2603.27277
- **Markus Harrer / iSAQB**：《AI Agents Don't Modernize Legacy Code on Their Own》—— 特征测试 + seam + 混合 AI（agent 写脚本、工具确定性执行）—— https://www.isaqb.org/blog/ai-agents-dont-modernize-legacy-code-on-their-own/
- **Ry Walker**：代码智能工具对比（17 工具，含许可证与隐私校正）—— https://rywalker.com/research/code-intelligence-tools
- **Thoughtworks**：Strangler Fig 模式（part one / three）—— https://www.thoughtworks.com/en-us/insights/articles/embracing-strangler-fig-pattern-legacy-modernization-part-one
- **Aider Repo Map**：tree-sitter + PageRank + token 预算 —— https://aider.chat/docs/repomap.html
- **OpenRewrite / ast-grep / Serena / codebase-memory-mcp** 官方文档与仓库

---

*本手册是可执行清单，不是读物。每个阶段做完就打勾，出口条件不达标就不要往下走。*

---

## 8. 修订记录 v1.1（自查后的三处修正）

1. **侦察脚本已降级为调度器**：phase0-recon.ps1 现在优先调用 scc / tokei / cloc / code-maat / jscpd，内置实现只作兜底，并在报告顶部标注数据来源。原先我手写的那部分是重复造轮子。
2. **本手册定位修正**：不再宣称「我的七阶段」，而是 aim42（Analyze → Evaluate → Improve）在 AI 时代的一个补丁——唯一新增的必选阶段是 P3「造裁判」。
3. **补上 Mikado Method**：原手册没有回答「改到一半发现动不了怎么办」，这是高频真实场景。

**另见** COMMUNITY-MAP.md：社区现有方法与流程图清单 + 我漏掉的现成工具 + 与本手册的对应关系。

