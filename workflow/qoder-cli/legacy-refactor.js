// legacy-refactor —— Qoder CLI 动态工作流壳（profile 由 args 决定）
//
// 放在项目 `.qoder/workflows/` 或用户级 `~/.qoder/workflows/` 下，然后说一句
//   "用 legacy-refactor 动态工作流重构 <某仓>"
//
// ★ 这层的定位要说清楚：**它不判门，它只是派工**。
//   真正的判据在 workflow/workflow-run.ps1 里（22 道门 + 密封产物 + 退出码口径）。
//   动态工作流脚本按官方文档**不能直接碰 shell / 文件系统 / 网络**，所有副作用都得经子 agent；
//   所以本文件的每个阶段都是"派一个子 agent 去跑执行器的那一段，并把 rc 与失败门的证据带回来"。
//   这样做的代价：门判强度没有因为这层壳而变高；好处是用户能一句话点单，并在运行前看到计划再放行。
//
// 未验证声明：本机 `qodercli status` = Not logged in，作者环境无法非交互登录，
//   所以本文件**没有跑通过**。语法照文档写，agent()/phase()/args 的精确签名以
//   `qodercli` 实际加载结果为准；第一次登录后必须先做"阶段数对不对、人工门能不能拦住"两条验证。

export const meta = {
  name: "legacy-refactor",
  description: "遗留系统重构：立界→测绘→定活→造裁判→小步改→强制拆除，每步出口是可执行、可密封的门",
  whenToUse: "面对一个没人懂、缺测试、可能是 AI 写的代码库，需要安全改造；或用户要求按重构流程接手一个仓",
  phases: [
    { title: "立界 A", detail: "写 SCOPE.md（in-scope / read-only / DoD），确认可判真假的完成定义，留退路" },
    { title: "测绘 B", detail: "跑 phase0-recon：语言/体量/热点/测试设施三态/入口点候选" },
    { title: "定活 C", detail: "入口点逐个打 LIVE/DEAD/UNKNOWN，写 TRIAGE.csv，带观测窗口与触达画像" },
    { title: "造裁判 D", detail: "基线跑绿 + mutation-probe 量裁判强度，报 MUT score 与漏放清单" },
    { title: "小步改 E", detail: "一个 PR 一个意图，每步都有探测器看着；行为差异全部登记" },
    { title: "拆除 T", detail: "台账 -Verify 全清 + -Sweep 无硬残留 + 孤儿按租约收走" },
  ],
};

// args：{ repo: "<目标仓绝对路径>", test: "<该仓跑测试的命令>", profile: "full" | "gate", confirm: "A,B,..." }
const repo = (args && args.repo) || ".";
const test = (args && args.test) || "";
const profile = (args && args.profile) || "full";
const confirm = (args && args.confirm) || "";

// 一次阶段 = 派一个子 agent 前台跑执行器的一段，并把 rc / failAt / 失败门的 detail 原样带回
function step(phaseId, goal) {
  return agent(
    [
      `在仓库 ${repo} 上执行重构工作流阶段 ${phaseId}（${goal}）。`,
      "命令（前台执行，工作目录切到技能仓）：",
      `powershell -NoProfile -ExecutionPolicy Bypass -File workflow/workflow-run.ps1 -RepoPath "${repo}" -TestCmd "${test}" -Profile ${profile} -FromPhase ${phaseId}` +
        (confirm ? ` -Confirm ${confirm}` : ""),
      "只报事实，不许替用户判断：",
      "1) 退出码原样报（0 complete / 1 failed / 2 安装或用法故障 / 3 partial-INCONCLUSIVE）；",
      "2) 停在哪个门：读该 run 目录 run-manifest.json 的 failAt，并把 gates.json 里那条的 detail（含输出尾部）逐字贴出来；",
      "3) coverage.json 里的 unknown 与 notChecked 必须原样转述，缺席不等于已解决；",
      "4) 遇到 op=human 的门只许停下报'等用户放行'，**不许自行加 -Confirm**，也不许把'用户大概会同意'当放行；",
      "5) rc 非 0 时交付措辞受限：只能写'跑到哪停住'，不许写'基本完成'。",
    ].join("\n"),
    { label: `wf-${phaseId}` }
  );
}

const results = [];
for (const ph of meta.phases) {
  const id = ph.title.split(" ")[0];
  // profile=gate 时跳过 A 与 C（轻量档：B/D/E/T）
  if (profile === "gate" && (id === "A" || id === "C")) {
    log(`跳过阶段 ${id}（profile=gate 不含它；全量结论请用 profile=full）`);
    continue;
  }
  phase(ph.title);
  results.push({ phase: id, outcome: await step(id, ph.detail) });
}

return {
  profile,
  repo,
  阶段读数: results,
  口径: "本壳不判门；门与密封在 workflow/workflow-run.ps1。任何 rc≠0 ⇒ 交付只能写'跑到哪停住'。",
};
