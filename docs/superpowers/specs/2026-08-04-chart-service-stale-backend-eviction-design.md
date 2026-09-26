# 图表后端残留进程清理(重启即生效)设计

日期:2026-08-04
状态:已实施(2026-08-04)
关联文档:`2026-08-04-smartchart-thinking-model-fix-design.md`(本次暴露问题的修复)

## 1. 问题

只改 ChartAgent(Python)代码、在 Xcode 里重新构建并启动 app 后,新代码不生效:
旧 app 实例留下的 Python 后台进程(孤儿)仍占用 8765 端口,新实例的
`ChartServiceManager.ensureServiceRunning` 第一步 `checkHealth()` 成功就直接收养它。
健康检查只比对 `serviceVersion`(`5.0.0`),而普通代码修复不动版本号,导致
"版本相同但代码更旧"的进程被当作健康服务沿用,用户看到的仍是旧行为。

2026-08-04 实际发生:15:21 重建并重开 app,14:43 启动的旧 Python 进程继续服务,
思考型模型修复迟迟不生效,杀掉旧进程后恢复。

## 2. 设计

`ensureServiceRunning`(`AIRecording/Services/ChartServiceManager.swift`)的复用
条件增加进程所有权判断:

- 仅当 `process != nil && process.isRunning`(本实例亲自拉起且仍存活)且健康检查
  通过时,才复用现有后端;
- 否则(包括端口上躺着上一实例的孤儿、外来进程)一律先 `killListenersOnPort`
  清场,再启动捆绑的新后端。

效果:任何代码修改后重启 app,后端必定是新构建。代价是每次启动多 1~2s 的
Python 拉起时间,仅在首次用图表功能时发生。

已知边界(可接受,不劣于现状):同时跑两个 app 实例时,后启动者会顶掉前者的
后端,前者经健康检查继续共享后者的新后端。

## 3. 测试

不加新单测:该路径需要真实进程与端口编排,性价比低。以现有
`SmartChartTests`(isSupportedHealth / serviceEnvironment 等)防回归,并手动验证:
重启 app 后旧孤儿进程被清理、`/health` 由新进程提供。

## 4. 改动文件

- `AIRecording/Services/ChartServiceManager.swift` — `ensureServiceRunning` 复用
  条件 + 注释
- `AGENTS.md` — 设计文档清单补本条
