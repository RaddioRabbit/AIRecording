# 程序坞图标常显 设计文档

日期：2026-07-20
状态：已获用户认可

## 背景与需求

当前 AIRecording 是纯菜单栏应用：`Info.plist` 中 `LSUIElement = true`，`AppDelegate` 启动时设置 `NSApp.setActivationPolicy(.accessory)`，因此程序坞（Dock）中没有图标。

用户需求：打开 `/Applications/AIRecording.app` 之后，程序坞里显示应用图标。经确认，期望行为为**一直显示**——只要 App 在运行，程序坞就有图标；菜单栏图标保留不变。

## 方案

采用方案 A：修改 `Info.plist` + 启动代码，让应用成为普通的 `.regular` 应用。

（被否决的方案 B：只改代码不改 `Info.plist`，会造成配置与代码矛盾，维护困惑。）

## 改动内容

共三处，均为最小改动：

1. **`AIRecording/Info.plist`** — 删除 `LSUIElement` 键（当前在第 33-34 行）。
2. **`AIRecording/App/AIRecordingApp.swift`**（约第 29-30 行）— `AppDelegate.applicationDidFinishLaunching` 中将 `NSApp.setActivationPolicy(.accessory)` 改为 `NSApp.setActivationPolicy(.regular)`，并同步更新注释（原注释为 "Hide dock icon, show only in menu bar"）。
3. **`AIRecording/App/MenuBarController.swift`**（约第 236 行）— `openMainWindow()` 中的 `NSApp.setActivationPolicy(.regular)` 变为冗余，删除该行（应用启动时已是 `.regular`）。

## 行为变化

- 启动 App → 程序坞立即显示图标；点击程序坞图标可激活/聚焦主窗口。
- 菜单栏图标及全部现有功能（左键录音、右键菜单、最近录音、设置、退出）完全不变。
- 关闭主窗口后 App 不退出（与现状一致），程序坞图标保留，符合普通 Mac 应用习惯。

## 错误处理

无新增错误路径。`setActivationPolicy` 不涉及失败处理。

## 验证

1. `swift build` 编译通过。
2. `swift test` 测试通过（本改动无新逻辑，不新增测试）。
3. 用 `Scripts/build-app.sh` 打包新的 `.app`，替换 `/Applications/AIRecording.app` 后打开，人工确认：
   - 程序坞出现应用图标；
   - 菜单栏图标仍在，录音/转录功能正常。

## 文档同步

`AGENTS.md` 与 `CLAUDE.md` 中关于 `LSUIElement = true`（menu bar app, no dock）和 `.accessory` 的描述需在实施时一并更新。
