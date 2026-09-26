# AIRecording 应用图标落地实现设计

| 项目 | 内容 |
|------|------|
| 日期 | 2026-07-20 |
| 关联文档 | `2026-07-20-app-icon-prompt-design.md`（提示词设计） |
| 输入素材 | `pic/jimeng-2026-07-20-6521-*.png`（即梦生成，2048×2048） |
| 目标 | `/Applications/AIRecording.app` 显示新图标，且重建后不丢失 |

## 素材问题与处理

生成图存在两个问题，需预处理：

1. **右下角「即梦AI」水印** → 先裁掉底部 12% 画面（水印区域，主体图形不涉及），彻底去除。
2. **主体占比偏小（约 46%）** → 检测黑色/橙色像素得到主体包围盒，扩展为方形并重新居中，使主体占画面约 78%（macOS 图标惯例）。

随后套用 macOS 圆角蒙版（半径约 22.4%，角外透明），输出 1024×1024 主图，存至 `Assets/AppIcon-1024.png`（不入 Resources，避免打进 app 包）。

## 构建集成

- `AIRecording/Info.plist`：`CFBundleIconFile` 填 `AppIcon`（该 key 已存在，值为空）。
- `Scripts/build-app.sh` 新增图标生成步骤（在拷贝资源之后、签名之前）：
  1. 用 `sips` 从主图缩出 iconset 十档尺寸（16/32/128/256/512 的 @1x/@2x）
  2. `iconutil -c icns` 生成 `AppIcon.icns` 放入 `Contents/Resources/`
- 构建期只依赖 macOS 自带的 `sips` / `iconutil`，不引入 Python 依赖（Pillow 仅用于一次性主图制作）。

## 验证

1. `Scripts/build-app.sh` 构建成功
2. `/Applications/AIRecording.app/Contents/Resources/AppIcon.icns` 存在且可解析
3. 将 icns 转 PNG 目检，确认无水印、圆角透明、主体居中

## 边界（YAGNI）

- 不填充 `Assets.xcassets/AppIcon.appiconset`（SPM 构建不走 asset catalog 编译，icns 方案已覆盖）
- 不做 Dock 图标之外的任何品牌物料
