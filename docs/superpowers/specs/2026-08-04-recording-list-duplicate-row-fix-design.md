# 录音列表导入后出现重复行(幽灵行)修复设计

日期:2026-08-04
状态:已实施并验证
涉及文件:`AIRecording/Views/RecordingListView.swift`

## 问题现象

导入音频并触发转录后,录音列表中同一条录音显示为两行:一行半透明(幽灵行)+ 一行正常行,两行都显示"转录中" badge。

## 排查结论(全部经过实证)

1. **不是数据层重复**:SQLite 库中 Recording 仅 1 行、Transcription 仅 1 行,磁盘上导入的音频文件仅 1 份,转录日志只有 1 个任务。
2. **不是列表数据源重复**:在 `RecordingListViewModel.loadRecordings()` 中加入诊断输出后确认,每次刷新返回的数组元素 objectID 全部唯一(46 条数据、46 个唯一 ID),但 UI 渲染出 47 行。
3. **根因**:SwiftUI `List`(底层 NSTableView 桥接)在处理"数组整体替换"式更新时,若插入新行后约 0.3–3 秒内该行内容再次变化(导入流程:Recording 入库刷新一次 → Transcription 建档刷新第二次,行的"转录中" badge 出现),会遗留一个卡住的旧行渲染,形成半透明幽灵行,且持续存在直到 App 重启。
4. **被证伪的方案**:
   - 加大 debounce(0.3s → 1.2s)合并刷新:两次保存间隔可超过 1.2s,无法保证合并,幽灵行仍出现。
   - 移除冗余的 `.tag()` / `.onTapGesture()`(仅做此清理):幽灵行仍出现。

## 修复方案

将列表从 SwiftUI `List` 改为 `ScrollView + LazyVStack + ForEach`(普通视图 diff,不经过 NSTableView 桥接的动画/复用机制):

- 行保留原有 `RecordingRowView`,外观增加分隔线与选中高亮(`accentColor.opacity(0.12)`)。
- 行交互从 `List(selection:) + .tag + .onTapGesture` 改为 `Button + .buttonStyle(.plain)`,点击设置 `selectedRecordingObjectID` 打开详情,右键删除菜单不变。
- 数据流(`NSManagedObjectContextObjectsDidChange` + 300ms debounce + 整表替换)保持不变。

## 验证

- 复现环境:调试钩子自动导入同一文件,强制"插入→3 秒后 badge 出现"的分裂时序。
- List 版本:稳定复现幽灵行(3/3);LazyVStack 版本:合并时序与强制分裂时序均无幽灵行(2/2)。
- 交互回归:点击行进入详情 ✓、详情页"返回"回列表 ✓、右键删除菜单保留 ✓。
- `swift build` 通过,`swift test` 104 个测试全部通过。

## 附带发现(未在本修复范围内)

- 转录完成后的状态刷新依赖同一条手写通知链;在 App 窗口被最小化/完全遮挡(App Nap)时,刷新可能延迟,列表 badge 可能短暂停留在"转录中"。窗口可见时工作正常。如后续需要可单独处理。
