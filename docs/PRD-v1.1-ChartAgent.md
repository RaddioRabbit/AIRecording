# AIRecording — Chart Agent 扩展产品需求文档

## 版本信息

| 项目 | 内容 |
|------|------|
| 文档版本 | v1.1 |
| 撰写日期 | 2026/05/28 |
| 产品名称 | AIRecording（macOS 菜单栏录音应用） |
| 目标平台 | macOS 桌面端（Intel + Apple Silicon），最低 macOS 13 |
| 关联文档 | PRD-v1.0.md、TechSpec-v1.0.md、DatabaseDesign-v1.0.md |
| 变更说明 | 基于 v1.0 第 4.4 节"图表生成模块"大幅扩展；新增 Agent 化分析引擎、Skill 化封装机制、6 大图表场景、数据模型扩展、里程碑规划；**v1.1 更新：全面采用暗黑极客风（Dark Cyberpunk）视觉系统** |

### 变更点摘要

| 变更类型 | 内容 |
|----------|------|
| 新增 | 5.1 智能图表分析引擎（LangGraph Agent） |
| 新增 | 5.2 图表类型与模板系统（6 大类型 + 模板市场） |
| 新增 | 5.5 Skill 接口与复用机制 |
| 扩展 | 5.3 图表生成与渲染（WKWebView + 自定义 HTML/CSS 方案细化，全面支持暗黑极客风） |
| 扩展 | 5.4 图表编辑与交互（从 P2 提升至 P1） |
| 扩展 | 5.6 导出与分享（新增 JSON/CSV/可编辑格式导出） |
| 扩展 | 第 6 章数据模型扩展（Chart 实体重构 + ChartNode/ChartEdge/ChartJob 新增） |
| 扩展 | 第 8 章验收标准（新增 Agent 决策准确率、Skill 接口稳定性等） |
| 调整 | 优先级：思维导图 P1 → P0，流程图 P2 → P1，交互式编辑 P2 → P1 |

---

## 1. 功能概述

### 1.1 Chart Agent 定位

Chart Agent 是 AIRecording 的**智能可视化中枢**，承接"转录完成 → 纪要生成"后的下一环，自动将非结构化的会议/访谈/课堂文本转化为**沉浸式暗黑极客风（Dark Cyberpunk）可视化图表**。它不是简单的模板填充工具，而是一个具备**内容理解能力**的智能 Agent，能够：

1. **自主决策**：分析文本内容，判断最适合的图表类型（而非让用户手动选择）
2. **结构化提取**：从文本中提取节点、关系、时间、数值等结构化要素
3. **多模态生成**：生成思维导图、流程图、时间线、数据对比图、组织架构图、看板等多种图表，全部采用统一的暗黑极客风视觉系统
4. **可复用输出**：图表生成能力封装为 Skill，可被纪要模块、历史模块、第三方插件调用，输出暗黑极客风 HTML 片段或渲染配置 JSON

### 1.2 价值主张

**"转录完成，图表即现"** —— 用户无需学习任何图表工具，录音结束即可获得与内容匹配的可视化呈现。所有图表采用统一的暗黑极客风（Dark Cyberpunk）视觉系统，以深色沉浸背景、霓虹强调色和毛玻璃质感，将枯燥的会议纪要转化为具有科技感和专业度的可视化作品。

### 1.3 与现有模块的关系

```
录音结束 → 本地转录 → 纪要生成 → [Chart Agent] → 可视化图表
                ↓                              ↓
           转录文本                        Skill 调用
           （本地存储）                    （可被其他模块复用）
```

---

## 2. 范围边界

### 2.1 范围内（In Scope）

#### 核心功能
- **智能图表分析引擎**：基于 LangGraph 的 Agent，自动分析文本并决策图表类型
- **暗黑极客风视觉系统**：核心视觉交付，包含完整的设计 Token（配色、圆角、阴影、字体、间距）和 CSS 变量体系
- **6 大图表类型**：思维导图、流程图、时间线、数据对比图（饼图/柱状图）、组织架构图、会议纪要看板，全部适配暗黑极客风
- **自动触发**：纪要生成完成后自动启动 Chart Agent 分析
- **图表渲染**：主方案为 WKWebView + 自定义 HTML/CSS（支持完整暗黑极客风格）；备选方案为 SVG 原生渲染
- **交互式编辑**：支持节点增删改、拖拽布局、样式调整
- **多格式导出**：PNG、SVG、JSON（可编辑格式）、Markdown 嵌入代码、暗黑极客风 HTML 片段

#### Agent 化范围
- Agent 状态图设计（分析 → 决策 → 提取 → 生成 → 校验）
- 图表类型决策逻辑（基于内容特征的自动匹配）
- 与纪要生成模块的衔接（输入：结构化纪要 JSON；输出：图表结构化数据 + 暗黑极客风渲染配置）
- 本地 Python 运行时集成（LangGraph 为 Python 框架，通过子进程/本地服务与 Swift 通信）

#### Skill 化范围
- Chart Skill 的公共接口定义（输入协议、输出协议、错误码）
- Skill 注册与发现机制（其他模块可通过名称调用 Chart Skill）
- Skill 配置参数（图表类型覆盖、样式主题、输出格式偏好）
- Skill 版本管理与兼容性保证

### 2.2 范围外（Out of Scope）

- **实时图表生成**：录音过程中实时生成图表（当前仅在纪要完成后触发）
- **手写/手绘识别**：不支持将手绘草图转换为数字图表
- **3D 图表**：不支持三维可视化
- **动态数据图表**：不支持连接实时数据源自动刷新
- **协作编辑**：不支持多人同时编辑同一张图表
- **图表模板市场服务端**：仅支持本地预设模板（含暗黑极客风预设模板集），不实现云端模板商店
- **LangGraph 训练/微调**：使用预训练模型 + Prompt 工程，不涉及模型训练
- **跨应用图表互通**：不实现与 Figma、Miro、Notion 等第三方应用的深度集成（仅通过导出文件互通）

### 2.3 Agent 化与 Skill 化的边界定义

| 维度 | Agent 化（In Scope） | Agent 化（Out of Scope） |
|------|----------------------|-------------------------|
| 状态管理 | LangGraph 状态图（分析→决策→提取→生成→校验） | 分布式多 Agent 协作 |
| 推理能力 | 单轮/多轮文本分析，图表类型决策 | 多模态输入（音频/视频直接分析） |
| 集成方式 | 本地 Python 子进程 / HTTP 服务 | 云端 Agent 服务部署 |

| 维度 | Skill 化（In Scope） | Skill 化（Out of Scope） |
|------|----------------------|-------------------------|
| 接口协议 | Swift 协议定义，输入/输出标准化；输出支持暗黑极客风 HTML 片段和渲染配置 JSON | 跨语言 Skill 市场（如 MCP 生态） |
| 复用范围 | AIRecording 内部各模块间复用 | 第三方应用调用本应用 Skill |
| 配置管理 | 本地 UserDefaults + 运行时参数；支持暗黑极客风设计 Token 自定义 | 云端 Skill 配置中心 |

---

## 3. 用户故事与场景

### 3.1 用户角色补充

在 v1.0 四 personas 基础上，Chart Agent 主要服务：
- **职场人士（李明）**：需要快速产出会议可视化产出物，发送给团队
- **学生/研究者（王浩）**：需要将复杂讲座内容结构化，便于复习
- **项目经理（新增）**：需要追踪项目时间线和决策流程

### 3.2 六大核心场景

#### 场景一：会议结构脑图（思维导图）

| 项目 | 内容 |
|------|------|
| **场景编号** | US-CHT-01 |
| **用户** | 职场人士 — 李明 |
| **触发条件** | 产品需求评审会结束，纪要已生成 |
| **用户目标** | 将会议讨论的产品功能结构以脑图形式呈现，便于团队对齐 |
| **文本特征** | 包含层级化的功能模块、子功能点、优先级讨论 |
| **Agent 决策** | 检测到大量层级化主题-子主题结构 → 选择思维导图 |
| **预期输出** | 中心节点为会议主题，一级分支为功能模块，二级分支为子功能，叶子节点标注优先级和负责人 |
| **暗黑极客风视觉呈现** | 深色背景（`#0F0F1A`）+ 中心节点采用 cyan-purple 渐变文字（`#22D3EE` → `#8B5CF6`）+ 一级分支节点左侧 cyan 彩色边框（`#22D3EE`）+ 二级分支节点左侧 purple 彩色边框（`#8B5CF6`）+ 叶子节点采用绿色（`#34C759`）或橙色（`#F59E0B`）状态标签 + 节点间青色渐变连接线 + 圆角卡片（16px）+ 悬浮阴影效果 |
| **验收标准** | 脑图层级与纪要结构一致；节点数 >= 5 个；生成时间 < 30 秒；配色符合暗黑极客风设计系统 |

#### 场景二：决策流程图（流程图）

| 项目 | 内容 |
|------|------|
| **场景编号** | US-CHT-02 |
| **用户** | 项目经理 |
| **触发条件** | 技术方案评审会结束，纪要包含多个决策点和条件分支 |
| **用户目标** | 将决策逻辑可视化，便于后续执行时参考 |
| **文本特征** | 包含"如果...则..."、"取决于..."、"方案 A / 方案 B"等条件表达 |
| **Agent 决策** | 检测到条件判断、分支逻辑 → 选择流程图 |
| **预期输出** | 开始节点 → 条件判断菱形 → 分支路径 → 结束节点，每条路径标注决策人和时间 |
| **暗黑极客风视觉呈现** | 左侧 cyan-purple 渐变时间线（`linear-gradient(to bottom, #22D3EE, #8B5CF6)`）+ 圆点标记（24px 圆形，cyan 边框）+ 步骤卡片采用 `#1E1E2E` 卡片背景 + 16px 圆角 + 条件判断节点采用橙色（`#F59E0B`）边框高亮 + 通过路径绿色（`#34C759`）标签 + 拒绝路径红色（`#FF3B30`）标签 + 毛玻璃质感悬浮效果 |
| **验收标准** | 流程图正确反映决策逻辑，无死路；条件分支完整；生成时间 < 30 秒；配色符合暗黑极客风设计系统 |

#### 场景三：项目时间线（时间线）

| 项目 | 内容 |
|------|------|
| **场景编号** | US-CHT-03 |
| **用户** | 项目经理 |
| **触发条件** | 项目周会结束，纪要包含多个里程碑和截止日期 |
| **用户目标** | 将项目关键节点可视化，便于跟踪进度 |
| **文本特征** | 包含明确日期、"截止"、"里程碑"、"阶段"等时间相关表达 |
| **Agent 决策** | 检测到 >= 3 个时间戳或日期表达 → 选择时间线 |
| **预期输出** | 横向时间轴，节点为里程碑/任务，标注日期、负责人、状态（讨论中/已确定/已完成） |
| **暗黑极客风视觉呈现** | 横向时间轴贯穿画布，时间节点采用 tech-item 风格卡片（`#1E1E2E` 背景 + 左侧彩色边框标签：已确定用 cyan `#22D3EE`、进行中用 orange `#F59E0B`、已完成用 green `#34C759`、讨论中用 purple `#8B5CF6`）+ 时间轴主线采用 cyan-purple 渐变 + 里程碑节点发光效果 + 事件卡片 16px 圆角 + 悬浮阴影 |
| **验收标准** | 时间顺序正确；日期提取准确率 >= 90%；生成时间 < 30 秒；配色符合暗黑极客风设计系统 |

#### 场景四：数据对比图（饼图/柱状图）

| 项目 | 内容 |
|------|------|
| **场景编号** | US-CHT-04 |
| **用户** | 职场人士 — 李明 |
| **触发条件** | 季度复盘会结束，纪要包含预算分配、用户数据、投票结果等数值信息 |
| **用户目标** | 将数值对比信息可视化，便于汇报 |
| **文本特征** | 包含百分比、数值对比、"占比"、"增长"、"投票结果"等数据表达 |
| **Agent 决策** | 检测到可量化的分类数据 → 选择饼图（占比）或柱状图（对比） |
| **预期输出** | 饼图：各分类占比，标注数值和百分比；柱状图：各分类数值对比，标注具体数值 |
| **暗黑极客风视觉呈现** | 双栏 dual-card 对比布局（蓝色边框 `#3B82F6` vs 紫色边框 `#8B5CF6`）+ 数据卡片采用 `#1E1E2E` 背景 + 16px 圆角 + 统计数字采用大号 cyan 色（`#22D3EE`，36px 加粗）+ 标签小字采用次要文字色（`#94A3B8`）+ 饼图区块使用 neon 色系（cyan / purple / orange / green / red）+ 柱状图柱子采用渐变填充（cyan → purple）+ 毛玻璃悬浮效果 |
| **验收标准** | 数值与原文一致；图表类型选择合理（占比用饼图、对比用柱状图）；生成时间 < 30 秒；配色符合暗黑极客风设计系统 |

#### 场景五：组织架构图（组织结构图）

| 项目 | 内容 |
|------|------|
| **场景编号** | US-CHT-05 |
| **用户** | HR / 团队负责人 |
| **触发条件** | 团队调整沟通会结束，纪要包含人员汇报关系调整 |
| **用户目标** | 将新的团队结构可视化，便于全员理解 |
| **文本特征** | 包含人名、职位、"汇报给"、"负责"、"下属"等组织关系表达 |
| **Agent 决策** | 检测到 >= 3 个人名及汇报/负责关系 → 选择组织架构图 |
| **预期输出** | 树状结构，根节点为最高负责人，子节点为下属，标注职位和负责领域 |
| **暗黑极客风视觉呈现** | 架构分层 arch-diagram 风格 + 每层采用不同 neon 彩色边框（根节点 cyan `#22D3EE`、第二层 purple `#8B5CF6`、第三层 orange `#F59E0B`、第四层 green `#34C759`）+ 每层背景使用对应颜色的 8% 透明度填充 + 层间箭头连接（`↓` 符号，灰色 `#94A3B8`）+ 节点卡片 12px 圆角 + 职位标签采用 tech-item 左侧彩色边框小卡片 + 整体外框 16px 圆角 + `#1E1E2E` 背景 |
| **验收标准** | 汇报关系正确；人名提取准确率 >= 85%；生成时间 < 30 秒；配色符合暗黑极客风设计系统 |

#### 场景六：会议纪要看板（Kanban 看板）

| 项目 | 内容 |
|------|------|
| **场景编号** | US-CHT-06 |
| **用户** | 职场人士 — 李明 |
| **触发条件** | 任何会议结束，纪要包含待办事项和状态跟踪 |
| **用户目标** | 将待办事项以看板形式呈现，便于任务跟踪 |
| **文本特征** | 包含"待办"、"进行中"、"已完成"、"负责人"、"截止日期"等任务管理表达 |
| **Agent 决策** | 检测到 >= 3 个待办事项 → 选择看板（可与时间线同时生成） |
| **预期输出** | 三列看板：待办 / 进行中 / 已完成，卡片包含事项内容、负责人、截止日期、关联会议主题 |
| **暗黑极客风视觉呈现** | 统计卡片面板（stat-num + stat-label 风格）+ 三列看板每列顶部显示大号统计数字（待办数/进行中数/已完成数，cyan 色 `#22D3EE`）+ 任务卡片采用 `#1E1E2E` 背景 + 左侧状态色边框（待办 purple `#8B5CF6`、进行中 orange `#F59E0B`、已完成 green `#34C759`）+ 卡片 16px 圆角 + 终端风格关键指标区（深色背景 `#0A0A14` + 等宽字体 + 语法高亮显示关键数据）+ 悬浮阴影效果 |
| **验收标准** | 待办事项完整无遗漏；状态分类合理；生成时间 < 20 秒；配色符合暗黑极客风设计系统 |

### 3.3 用户故事汇总

| 编号 | 用户故事 | 关联场景 | 优先级 |
|------|----------|----------|--------|
| US-CHT-01 | 作为职场人士，我希望会议的功能讨论自动转为思维导图，以便团队快速对齐结构 | 场景一 | P0 |
| US-CHT-02 | 作为项目经理，我希望决策逻辑自动转为流程图，以便执行时参考 | 场景二 | P1 |
| US-CHT-03 | 作为项目经理，我希望项目节点自动转为时间线，以便跟踪进度 | 场景三 | P1 |
| US-CHT-04 | 作为职场人士，我希望数值信息自动转为饼图/柱状图，以便汇报展示 | 场景四 | P1 |
| US-CHT-05 | 作为团队负责人，我希望人员调整自动转为组织架构图，以便全员理解 | 场景五 | P2 |
| US-CHT-06 | 作为职场人士，我希望待办事项自动转为看板，以便任务跟踪 | 场景六 | P1 |
| US-CHT-07 | 作为用户，我希望 Chart Agent 能自动判断生成什么图表，无需手动选择 | 全部 | P0 |
| US-CHT-08 | 作为用户，我希望图表可以交互编辑（增删节点、调整布局），以便修正 AI 理解偏差 | 全部 | P1 |
| US-CHT-09 | 作为用户，我希望图表可以导出为 PNG/SVG/JSON，以便在不同场景使用 | 全部 | P0 |
| US-CHT-10 | 作为开发者，我希望图表生成能力封装为可复用 Skill，以便在其他模块调用 | 全部 | P0 |
| US-CHT-11 | 作为用户，我希望图表生成过程可查看进度和可取消，以便控制等待时间 | 全部 | P1 |
| US-CHT-12 | 作为隐私敏感用户，我希望图表生成在本地完成，原始文本不上传 | 全部 | P0 |

---

## 4. 功能模块详细定义

### 4.1 智能图表分析引擎（Agent 核心）

#### 4.1.1 功能描述

Chart Agent 是基于 LangGraph 框架构建的智能分析流水线，接收结构化纪要 JSON 作为输入，输出图表类型决策 + 图表结构化数据 + 暗黑极客风渲染配置 JSON。整个流程在本地 Python 运行时中执行，转录文本经脱敏处理后传入。

#### 4.1.2 Agent 状态图（高层设计）

```
[Start] → [文本分析 State] → [图表决策 State] → [结构化提取 State] → [渲染配置生成 State] → [校验 State] → [End]
              ↓                      ↓                      ↓                          ↓                  ↓
         内容类型识别          图表类型选择          节点/边/时间提取      暗黑极客风 HTML/CSS 生成    语法+语义校验
         特征向量提取          置信度计算            数值/日期标准化       样式模板 + 设计 Token 应用   错误重试
```

**状态说明**：

| 状态 | 输入 | 输出 | 职责 |
|------|------|------|------|
| 文本分析 | 纪要 JSON | 内容特征向量 | 识别文本中的结构特征（层级、条件、时间、数值、人名关系、任务） |
| 图表决策 | 特征向量 | 图表类型 + 置信度 | 基于规则 + LLM 判断最适合的 1-3 种图表类型，按置信度排序 |
| 结构化提取 | 纪要 JSON + 图表类型 | 结构化数据（节点/边/时间/数值列表） | 从文本中提取图表所需的结构化要素 |
| 渲染配置生成 | 结构化数据 + 图表类型 | 暗黑极客风 HTML/CSS 字符串 + 渲染配置 JSON | 将结构化数据转换为自定义 HTML/CSS，应用暗黑极客风设计 Token 和样式模板 |
| 校验 | HTML/CSS + 渲染配置 | 校验结果（通过/错误信息） | 语法校验 + 语义校验（如流程图是否有死路）+ 视觉规范校验（配色、圆角、阴影） |

#### 4.1.3 图表类型决策矩阵

| 检测特征 | 权重 | 匹配图表类型 | 置信度阈值 |
|----------|------|-------------|-----------|
| 层级化主题-子主题 >= 3 层 | 0.9 | 思维导图 | >= 0.7 |
| 条件判断表达 >= 2 个 | 0.85 | 流程图 | >= 0.7 |
| 日期/时间表达 >= 3 个 | 0.8 | 时间线 | >= 0.6 |
| 数值/百分比/占比表达 >= 3 个 | 0.75 | 饼图/柱状图 | >= 0.6 |
| 人名 + 汇报/负责关系 >= 3 组 | 0.8 | 组织架构图 | >= 0.6 |
| 待办事项 >= 3 个 | 0.7 | 看板 | >= 0.5 |

**决策逻辑**：
1. 提取所有特征，计算各图表类型加权得分
2. 得分 >= 阈值且排名第一的图表类型被选中
3. 若多个类型得分均 >= 阈值，生成主图表 + 辅助图表（如时间线 + 看板）
4. 若无类型达到阈值，降级为通用思维导图（以会议主题为根节点）

#### 4.1.4 输入/输出协议

**输入协议（Swift → Python）**：

```json
{
  "version": "1.0",
  "requestId": "uuid",
  "content": {
    "theme": "会议主题",
    "participants": ["参与人1", "参与人2"],
    "keyDecisions": ["决策1", "决策2"],
    "actionItems": [
      {"content": "事项", "assignee": "负责人", "deadline": "日期"}
    ],
    "timeline": ["时间点1: 事件"],
    "markdownContent": "完整 Markdown 纪要",
    "rawTranscription": "脱敏后的完整转录文本（可选）"
  },
  "preferences": {
    "primaryChartType": "auto",
    "styleTheme": "darkCyberpunk",
    "outputFormats": ["html", "png", "svg"]
  }
}
```

**输出协议（Python → Swift）**：

```json
{
  "version": "1.0",
  "requestId": "uuid",
  "status": "success",
  "charts": [
    {
      "chartType": "mindmap",
      "chartTypeDisplayName": "思维导图",
      "confidence": 0.92,
      "htmlFragment": "<div class=\"chart-dark-cyberpunk\">...</div>",
      "renderConfig": {
        "styleTokens": {
          "bg": "#0F0F1A",
          "cardBg": "#1E1E2E",
          "border": "#33334D",
          "text": "#E2E8F0",
          "textSecondary": "#94A3B8",
          "cyan": "#22D3EE",
          "purple": "#8B5CF6",
          "orange": "#F59E0B",
          "green": "#34C759",
          "red": "#FF3B30",
          "blue": "#3B82F6",
          "cardRadius": "16px",
          "cardShadow": "0 12px 32px rgba(0,0,0,0.3)",
          "glassBlur": "blur(12px)",
          "gradientText": "linear-gradient(135deg, #22D3EE, #8B5CF6)",
          "terminalBg": "#0A0A14"
        }
      },
      "structuredData": {
        "nodes": [{"id": "1", "label": "会议主题", "level": 0}],
        "edges": [{"from": "1", "to": "2"}]
      },
      "metadata": {
        "nodeCount": 12,
        "maxDepth": 3,
        "generationTimeMs": 4500
      }
    }
  ],
  "errors": []
}
```

#### 4.1.5 错误处理

| 错误场景 | 处理方式 |
|----------|----------|
| Agent 运行时未启动 | 显示"图表引擎启动中"，自动重试 3 次后提示用户检查安装 |
| 文本过短（< 100 字） | 返回空结果，提示"内容过短，无法生成有意义的图表" |
| 决策置信度均 < 阈值 | 降级生成通用思维导图，标注"基于内容自动推断" |
| DSL 语法校验失败 | 自动修复常见语法错误（如非法字符转义），修复失败则返回错误 |
| Python 进程崩溃 | 自动重启进程，重试当前任务，失败 3 次后标记为失败 |
| 超时（> 60 秒） | 取消任务，提示"图表生成超时，请稍后重试" |

#### 4.1.6 技术实现占位

> **架构师确认后补充**：
> - LangGraph 状态图的具体节点/边定义
> - Python 运行时集成方案（子进程 vs 本地 HTTP 服务 vs XPC）
> - LLM 调用方案（本地模型 vs 云端 API，需考虑隐私约束）
> - 暗黑极客风 HTML/CSS 生成 Prompt 模板
> - 进程生命周期管理（启动、保活、重启、退出）

---

### 4.2 图表类型与模板系统

#### 4.2.1 支持的图表类型

| 图表类型 | 标识符 | 渲染方式 | 优先级 | 适用场景 | 暗黑极客风视觉特征 |
|----------|--------|---------|--------|----------|---------------------|
| 思维导图 | `mindmap` | 自定义 HTML/CSS（WKWebView） | P0 | 层级结构、知识梳理 | 深色背景 + 中心节点 cyan-purple 渐变 + 层级彩色边框节点 + 青色渐变连接线 |
| 流程图 | `flowchart` | 自定义 HTML/CSS（WKWebView） | P1 | 决策逻辑、业务流程 | 左侧 cyan-purple 渐变时间线 + 圆点标记 + 圆角步骤卡片 + 条件节点橙色高亮 |
| 时间线 | `timeline` | 自定义 HTML/CSS（WKWebView） | P1 | 项目里程碑、历史事件 | 横向渐变时间轴 + tech-item 事件卡片（左侧状态色边框）+ 里程碑发光效果 |
| 饼图 | `pie` | 自定义 SVG/Canvas | P1 | 占比分布、投票结果 | dual-card 布局 + neon 色系区块 + 大号 cyan 统计数字 + 毛玻璃卡片 |
| 柱状图 | `bar` | 自定义 SVG/Canvas | P2 | 数值对比、增长趋势 | 渐变填充柱子（cyan → purple）+ `#1E1E2E` 背景 + 次要文字色坐标轴标签 |
| 组织架构图 | `orgchart` | 自定义 HTML/CSS（WKWebView） | P2 | 团队结构、汇报关系 | 架构分层 arch-diagram 风格 + 彩色边框分层区块 + 箭头连接 + 职位 tech-item 标签 |
| 看板 | `kanban` | 自定义 HTML/CSS（WKWebView） | P1 | 任务跟踪、状态管理 | 统计数字卡片（stat-num + stat-label）+ 三列状态色边框卡片 + 终端风格关键指标区 |

#### 4.2.2 模板系统

**模板结构**：

```
ChartTemplate
├── templateId: String
├── chartType: ChartType
├── displayName: String
├── description: String
├── styleConfig: ChartStyleConfig
│   ├── theme: String (darkCyberpunk / dark / colorful / minimal)
│   ├── nodeColors: [String]           // 暗黑极客风 neon 色板
│   ├── edgeStyle: String
│   ├── fontFamily: String
│   ├── fontSize: Int
│   └── darkCyberpunkTokens: DarkCyberpunkTokens  // 新增：暗黑极客风设计 Token
│       ├── bg: #0F0F1A
│       ├── cardBg: #1E1E2E
│       ├── border: #33334D
│       ├── text: #E2E8F0
│       ├── textSecondary: #94A3B8
│       ├── cyan: #22D3EE
│       ├── purple: #8B5CF6
│       ├── orange: #F59E0B
│       ├── green: #34C759
│       ├── red: #FF3B30
│       ├── blue: #3B82F6
│       ├── cardRadius: 16px
│       ├── cardBorder: 1px solid #33334D
│       ├── cardShadow: 0 12px 32px rgba(0,0,0,0.3)
│       ├── glassBlur: blur(12px)
│       ├── glassBg: rgba(15, 15, 26, 0.85)
│       ├── gradientText: linear-gradient(135deg, #22D3EE, #8B5CF6)
│       ├── terminalBg: #0A0A14
│       └── techItemBorderWidth: 3px
├── layoutConfig: ChartLayoutConfig
│   ├── direction: String (TD / LR / RL / BT)
│   ├── rankSpacing: Int
│   └── nodeSpacing: Int
└── renderConfig: JSON (传递给 WKWebView 的 CSS/JS 初始化配置)
```

**预设模板**：

| 模板名称 | 图表类型 | 暗黑极客风风格特征 | 适用场景 |
|----------|----------|---------------------|----------|
| 默认思维导图 | mindmap | 深色背景 + 中心节点 cyan-purple 渐变 + 层级彩色边框节点 + 青色渐变连接线 | 通用会议 |
| 产品需求脑图 | mindmap | 中心节点渐变标题 + 优先级用 green/orange/red 左侧边框标签 + 子功能 purple 边框卡片 | 需求评审 |
| 决策流程图 | flowchart | 左侧 cyan-purple 渐变时间线 + 圆点标记 + 条件节点橙色边框 + 通过/拒绝 green/red 标签 | 技术评审 |
| 项目时间线 | timeline | 横向 cyan-purple 渐变时间轴 + tech-item 事件卡片（状态色左侧边框）+ 里程碑发光效果 | 项目周会 |
| 预算饼图 | pie | dual-card 对比布局 + neon 色系区块 + 大号 cyan 统计数字 + 毛玻璃卡片背景 | 财务复盘 |
| 团队架构图 | orgchart | 架构分层 arch-diagram 风格 + 每层不同 neon 彩色边框 + 箭头连接 + 职位 tech-item 标签 | 团队调整 |
| 敏捷看板 | kanban | 统计数字卡片（stat-num + stat-label）+ 三列状态色边框卡片 + 终端风格关键指标区 | 日常站会 |

#### 4.2.3 模板选择逻辑

1. Agent 根据内容特征选择图表类型
2. 根据会议主题关键词匹配最佳模板（如"需求评审"匹配"产品需求脑图"）
3. 用户可在设置中设置默认模板偏好
4. 生成后用户可切换模板，图表结构保持不变，仅样式变化

---

### 4.3 图表生成与渲染

#### 4.3.1 生成流程

```
纪要生成完成
    ↓
触发 ChartSkill.generate(recordingId, summaryJSON)
    ↓
组装输入协议 → 调用 Python Agent
    ↓
Agent 返回图表结构化数据 + 暗黑极客风渲染配置 JSON
    ↓
保存 Chart 实体到 Core Data
    ↓
渲染：WKWebView 加载自定义 HTML/CSS → 注入暗黑极客风 CSS 变量 → 渲染图表 → 截图/交互展示
    ↓
通知用户图表已生成
```

#### 4.3.2 渲染方案

**主方案：WKWebView + 自定义 HTML/CSS（暗黑极客风）**

| 维度 | 评估 |
|------|------|
| 实现复杂度 | 中：需构建暗黑极客风 CSS 框架，通过 WKWebView 注入渲染 |
| 性能 | 良：CSS 动画和渐变由 WebKit 硬件加速，首次加载需初始化样式表 |
| 离线能力 | 完整：完全本地渲染，无需网络 |
| 交互性 | 优：支持点击、缩放、拖拽（通过 JS Bridge），CSS 悬浮效果流畅 |
| 导出能力 | PNG/SVG：通过 WKWebView 截图；HTML 片段可直接嵌入 |
| 包体积 | 增加 ~500KB（自定义 CSS/JS，无需 Mermaid.js bundle） |
| 视觉一致性 | 优：完全控制每个像素，确保所有图表风格统一 |

**备选方案：SVG 原生渲染 + CSS 样式注入**

| 维度 | 评估 |
|------|------|
| 实现复杂度 | 中高：需为每种图表类型生成 SVG 路径，再注入暗黑极客风 CSS |
| 性能 | 优：原生 SVG 渲染，无 WebView 开销 |
| 离线能力 | 完整 |
| 交互性 | 良：SVG 支持基础交互，复杂交互需额外实现 |
| 导出能力 | PNG/SVG 原生支持 |
| 包体积 | 增加 ~200KB |

**决策**：主方案采用 WKWebView + 自定义 HTML/CSS（支持完整的暗黑极客风视觉系统：渐变文字、毛玻璃、发光效果、终端风格代码块）；SVG 原生渲染作为 P2 备选（用于导出和性能敏感场景）。

#### 4.3.3 暗黑极客风设计系统规范

**CSS 变量体系（WKWebView 注入）**：

```css
:root {
  --bg: #0F0F1A;
  --card: #1E1E2E;
  --border: #33334D;
  --text: #E2E8F0;
  --text-secondary: #94A3B8;
  --cyan: #22D3EE;
  --purple: #8B5CF6;
  --orange: #F59E0B;
  --green: #34C759;
  --red: #FF3B30;
  --blue: #3B82F6;
}
```

**核心设计 Token**：

| Token | 值 | 用途 |
|-------|-----|------|
| `bg` | `#0F0F1A` | 主背景色，所有图表画布背景 |
| `cardBg` | `#1E1E2E` | 卡片背景色，节点/区块背景 |
| `border` | `#33334D` | 边框色，分割线 |
| `text` | `#E2E8F0` | 主文字色，标题/节点文字 |
| `textSecondary` | `#94A3B8` | 次要文字色，描述/标签 |
| `cyan` | `#22D3EE` | 主强调色，中心节点、时间轴、统计数字 |
| `purple` | `#8B5CF6` | 次级强调色，二级节点、待办状态 |
| `orange` | `#F59E0B` | 警示/进行中状态，条件判断节点 |
| `green` | `#34C759` | 成功/已完成状态，通过路径 |
| `red` | `#FF3B30` | 错误/拒绝状态，拒绝路径 |
| `blue` | `#3B82F6` | 信息/对比色，双栏对比左侧边框 |
| `cardRadius` | `16px` | 卡片圆角，所有容器节点 |
| `cardBorder` | `1px solid #33334D` | 卡片边框样式 |
| `cardShadow` | `0 12px 32px rgba(0,0,0,0.3)` | 悬浮阴影 |
| `glassBlur` | `blur(12px)` | 毛玻璃模糊半径 |
| `glassBg` | `rgba(15, 15, 26, 0.85)` | 毛玻璃背景色 |
| `gradientText` | `linear-gradient(135deg, #22D3EE, #8B5CF6)` | 渐变文字（中心标题、大标题） |
| `terminalBg` | `#0A0A14` | 终端风格代码块背景 |
| `techItemBorderWidth` | `3px` | 左侧彩色边框标签宽度 |
| `fontFamily` | `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif` | 主字体 |
| `fontMono` | `"SF Mono", Monaco, "Cascadia Code", monospace` | 等宽字体（终端/代码） |
| `statNumSize` | `36px` | 统计数字字号 |
| `statLabelSize` | `13px` | 统计标签字号 |

**图表类型视觉定义**：

| 图表类型 | 背景 | 节点/卡片 | 连接线/时间轴 | 文字 | 特殊效果 |
|----------|------|-----------|---------------|------|----------|
| 思维导图 | `#0F0F1A` | `#1E1E2E` 圆角 16px，层级边框色（cyan/purple/orange/green） | cyan-purple 渐变线 | 主文字 `#E2E8F0`，中心标题渐变文字 | 悬浮阴影，节点发光 |
| 流程图 | `#0F0F1A` | `#1E1E2E` 圆角 16px 步骤卡片 | 左侧 cyan-purple 渐变竖线 + 圆点标记 | 主文字 `#E2E8F0`，条件节点橙色 | 步骤卡片悬浮上移 |
| 时间线 | `#0F0F1A` | tech-item 卡片（左侧 3px 状态色边框） | 横向 cyan-purple 渐变轴线 | 日期 cyan 色，描述 `#94A3B8` | 里程碑节点发光 |
| 饼图/柱状图 | `#0F0F1A` | dual-card 布局（blue/purple 边框） | 无 | 统计数字 cyan 36px，标签 `#94A3B8` 13px | 毛玻璃卡片，柱子渐变填充 |
| 组织架构图 | `#0F0F1A` | 分层 arch-diagram 区块（各层不同 neon 色 8% 透明度背景 + 对应色边框） | 层间箭头 `↓` `#94A3B8` | 职位 tech-item 小卡片 | 分层区块悬浮效果 |
| 看板 | `#0F0F1A` | 三列卡片（左侧状态色边框） | 无 | 统计数字 cyan 36px | 终端风格指标区 `#0A0A14` |

#### 4.3.4 渲染性能要求

| 指标 | 目标值 | 优先级 |
|------|--------|--------|
| 首次渲染时间 | < 3 秒（WKWebView 初始化 + CSS 样式注入 + 图表渲染） | P0 |
| 模板切换重渲染 | < 1 秒 | P1 |
| 节点数 <= 50 时帧率 | >= 30fps | P1 |
| 节点数 > 50 时处理 | 显示简化视图或分页 | P2 |
| 内存占用（渲染中） | < 100MB | P0 |

---

### 4.4 图表编辑与交互

#### 4.4.1 功能描述

用户可在应用内对生成的图表进行交互式编辑，修正 AI 理解偏差或补充信息。

#### 4.4.2 交互功能详情

| 功能点 | 优先级 | 说明 |
|--------|--------|------|
| 节点增删改 | P1 | 双击编辑节点文本，右键删除，工具栏添加同级/子级节点 |
| 拖拽布局 | P1 | 拖拽节点调整位置（HTML/CSS 有限支持，需评估可行性） |
| 缩放与平移 | P0 | 滚轮/捏合缩放，拖拽平移画布 |
| 节点样式调整 | P2 | 修改节点颜色、形状、边框 |
| 边样式调整 | P2 | 修改连线样式、箭头类型、标签 |
| 撤销/重做 | P1 | Cmd+Z / Cmd+Shift+Z |
| 实时预览 | P0 | 编辑后实时更新渲染结果 |
| 关联音频跳转 | P1 | 点击节点可跳转至对应音频时间戳（需转录时间戳对齐） |

#### 4.4.3 编辑持久化

- 编辑操作实时保存到 Core Data `ChartNode`/`ChartEdge` 实体
- 保留原始 AI 生成版本，编辑后创建用户版本（版本管理）
- 支持"重置为 AI 生成版本"

---

### 4.5 Skill 接口与复用机制

#### 4.5.1 Skill 定位

Chart Skill 是 AIRecording 内部的能力单元，遵循统一的 Skill 协议，可被任何模块调用。

#### 4.5.2 Skill 接口定义

```swift
// Skill 协议（通用）
protocol AppSkill {
    var skillId: String { get }
    var skillVersion: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get }
    
    func configure(_ config: SkillConfiguration) async throws
    func execute(input: SkillInput) async throws -> SkillOutput
}

// Chart Skill 专用输入
struct ChartSkillInput: SkillInput {
    let sourceType: ChartSourceType  // .summary / .transcription / .customText
    let sourceData: Any              // Summary JSON / Transcription text / Custom string
    let preferredChartTypes: [ChartType]?
    let styleTheme: String?          // "darkCyberpunk" (default) / "dark" / "colorful" / "minimal"
    let outputFormats: [ChartOutputFormat]  // .htmlFragment / .png / .svg / .json / .markdown
}

// Chart Skill 专用输出
struct ChartSkillOutput: SkillOutput {
    let charts: [ChartResult]
    let processingTimeMs: Int
    let logs: [SkillLog]
}

struct ChartResult {
    let chartType: ChartType
    let confidence: Double
    let htmlFragment: String?           // 暗黑极客风 HTML 片段（WKWebView 直接渲染）
    let renderConfig: RenderConfig?     // 渲染配置 JSON（含 style tokens）
    let structuredData: ChartStructuredData
    let previewImageData: Data?         // 缩略图
}

struct RenderConfig {
    let styleTokens: [String: String]   // 暗黑极客风设计 Token 键值对
    let cssFramework: String            // 内联 CSS 框架版本
    let jsInterop: String?              // JS Bridge 交互配置
}
```

#### 4.5.3 Skill 注册与发现

```swift
// Skill Registry（单例）
class SkillRegistry {
    static let shared: SkillRegistry
    
    func register(_ skill: AppSkill)
    func skill(byId: String) -> AppSkill?
    func skills(ofCategory: SkillCategory) -> [AppSkill]
}

// 使用示例
let chartSkill = SkillRegistry.shared.skill(byId: "chart.agent.v1")
let output = try await chartSkill.execute(input: chartInput)
```

#### 4.5.4 复用场景

| 调用方 | 场景 | 输入 | 输出使用方式 |
|--------|------|------|-------------|
| 纪要模块 | 纪要生成完成后自动触发 | Summary JSON | 展示在录音详情页 |
| 历史模块 | 用户选择旧录音生成图表 | Recording ID | 异步生成，通知用户 |
| 导出模块 | 批量导出时包含图表 | Recording ID | 嵌入导出 ZIP |
| 第三方（未来） | 通过 AppleScript/Shortcuts 调用 | 自定义文本 | 返回图表文件路径 |

#### 4.5.5 Skill 配置

```swift
struct ChartSkillConfiguration: SkillConfiguration {
    let pythonRuntimePath: String?      // 自定义 Python 路径
    let llmProvider: LLMProvider        // .local / .openai / .anthropic
    let apiKey: String?                 // 云端 LLM API Key
    let defaultTheme: String            // 默认样式主题（默认 "darkCyberpunk"）
    let darkCyberpunkTokens: [String: String]?  // 自定义暗黑极客风设计 Token 覆盖
    let maxChartsPerRequest: Int        // 单次最大生成图表数（默认 3）
    let timeoutSeconds: Int             // 超时时间（默认 60）
    let enableAutoGenerate: Bool        // 是否自动触发（默认 true）
}
```

---

### 4.6 导出与分享

#### 4.6.1 导出格式

| 格式 | 扩展名 | 内容 | 优先级 |
|------|--------|------|--------|
| PNG 图片 | `.png` | 静态图片，分辨率可选（144dpi / 300dpi），暗黑极客风配色 | P0 |
| SVG 矢量 | `.svg` | 可缩放矢量图，保留文本可选中，内嵌暗黑极客风 CSS | P0 |
| JSON 可编辑 | `.chart.json` | 完整结构化数据 + 渲染配置（含 style tokens），可重新导入编辑 | P1 |
| Markdown 嵌入 | `.md` | 包含暗黑极客风 HTML 代码块的 Markdown | P1 |
| 暗黑极客风 HTML | `.html` | 完整自包含 HTML 文件，可直接在浏览器打开 | P1 |
| PDF | `.pdf` | 单页 PDF，适合打印 | P2 |
| CSV（仅数据图） | `.csv` | 节点/边数据表格 | P2 |

#### 4.6.2 导出选项

- 分辨率：144dpi（默认）/ 300dpi / 自定义
- 背景：透明 / 深色（暗黑极客风 `#0F0F1A`）/ 跟随主题（默认暗黑极客风）
- 尺寸：自适应 / 固定宽度 / 固定高度 / 自定义
- 包含水印：无 / 应用名称 / 自定义文字

#### 4.6.3 分享方式

- 拖拽导出：从图表视图直接拖拽 PNG 到桌面或其他应用
- 复制到剪贴板：复制 PNG 或 HTML 代码片段
- 系统分享面板：调用 NSSharingServicePicker

---

## 5. 数据模型扩展

### 5.1 实体变更总览

基于 DatabaseDesign-v1.0，Chart 相关实体需要重构和扩展：

| 实体 | 操作 | 说明 |
|------|------|------|
| Chart | 重构 | 扩展字段，支持多图表、版本管理 |
| ChartNode | 新增 | 图表节点数据 |
| ChartEdge | 新增 | 图表边/关系数据 |
| ChartJob | 新增 | 图表生成任务队列 |
| Recording | 修改 | 新增 `charts` 一对多关系 |
| Summary | 修改 | 新增 `isChartGenerated` 标志 |

### 5.2 Chart 实体（重构）

```swift
@objc(Chart)
public class Chart: NSManagedObject {
    // 基础标识
    @NSManaged public var id: UUID
    @NSManaged public var recordingId: UUID
    @NSManaged public var summaryId: UUID?
    
    // 图表类型与状态
    @NSManaged public var chartType: Int16        // ChartType rawValue
    @NSManaged public var chartTypeConfidence: Double
    @NSManaged public var status: Int16           // ChartStatus rawValue
    
    // 内容数据
    @NSManaged public var mermaidDefinition: String?
    @NSManaged public var styleTheme: String?
    @NSManaged public var templateId: String?
    
    // 元数据
    @NSManaged public var nodeCount: Int32
    @NSManaged public var edgeCount: Int32
    @NSManaged public var maxDepth: Int32
    @NSManaged public var generationTimeMs: Int32
    
    // 版本管理
    @NSManaged public var version: Int32          // 版本号，0=AI生成，>0=用户编辑版本
    @NSManaged public var isUserEdited: Bool
    @NSManaged public var parentChartId: UUID?    // 关联的原始版本
    
    // 导出缓存
    @NSManaged public var exportedImagePath: String?
    @NSManaged public var exportedSVGPath: String?
    
    // 时间戳
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    
    // 错误信息
    @NSManaged public var errorMessage: String?
    @NSManaged public var retryCount: Int32
    
    // 关系
    @NSManaged public var recording: Recording?
    @NSManaged public var nodes: NSSet?           // ChartNode
    @NSManaged public var edges: NSSet?           // ChartEdge
}
```

**ChartType 枚举**：

```swift
enum ChartType: Int16, CaseIterable {
    case mindmap = 0
    case flowchart = 1
    case timeline = 2
    case pie = 3
    case bar = 4
    case orgChart = 5
    case kanban = 6
    case unknown = 99
    
    var displayName: String {
        switch self {
        case .mindmap: return "思维导图"
        case .flowchart: return "流程图"
        case .timeline: return "时间线"
        case .pie: return "饼图"
        case .bar: return "柱状图"
        case .orgChart: return "组织架构图"
        case .kanban: return "看板"
        case .unknown: return "未知"
        }
    }
    
    var mermaidType: String? {
        switch self {
        case .mindmap: return "mindmap"
        case .flowchart, .orgChart: return "flowchart"
        case .timeline: return "timeline"
        case .pie: return "pie"
        case .bar: return nil  // 柱状图需自定义 SVG/Canvas 渲染
        case .kanban: return nil  // 需自定义 HTML
        case .unknown: return nil
        }
    }
}
```

**ChartStatus 枚举**：

```swift
enum ChartStatus: Int16 {
    case pending = 0       // 待生成
    case analyzing = 1     // Agent 分析中
    case generating = 2    // DSL 生成中
    case rendering = 3     // 渲染中
    case completed = 4     // 已完成
    case failed = 5        // 失败
    case cancelled = 6     // 已取消
}
```

### 5.3 ChartNode 实体（新增）

```swift
@objc(ChartNode)
public class ChartNode: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var chartId: UUID
    @NSManaged public var nodeId: String          // 图表内唯一标识（如 "1", "A"）
    @NSManaged public var label: String
    @NSManaged public var level: Int32            // 层级深度
    @NSManaged public var nodeType: Int16         // NodeType rawValue
    @NSManaged public var shape: String?          // 节点形状定义（用于 HTML/CSS 渲染）
    @NSManaged public var color: String?          // 自定义颜色
    @NSManaged public var metadata: String?       // JSON 格式的附加数据
    @NSManaged public var sequence: Int32         // 排序
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    
    // 关系
    @NSManaged public var chart: Chart?
    @NSManaged public var outgoingEdges: NSSet?   // ChartEdge
    @NSManaged public var incomingEdges: NSSet?   // ChartEdge
}

enum NodeType: Int16 {
    case root = 0
    case branch = 1
    case leaf = 2
    case decision = 3      // 流程图判断节点
    case milestone = 4     // 时间线里程碑
    case task = 5          // 看板任务
    case data = 6          // 数据节点
}
```

### 5.4 ChartEdge 实体（新增）

```swift
@objc(ChartEdge)
public class ChartEdge: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var chartId: UUID
    @NSManaged public var sourceNodeId: String
    @NSManaged public var targetNodeId: String
    @NSManaged public var label: String?          // 边标签
    @NSManaged public var edgeStyle: String?      // 实线/虚线/点线
    @NSManaged public var arrowType: String?      // 箭头类型
    @NSManaged public var sequence: Int32
    @NSManaged public var createdAt: Date
    
    // 关系
    @NSManaged public var chart: Chart?
    @NSManaged public var sourceNode: ChartNode?
    @NSManaged public var targetNode: ChartNode?
}
```

### 5.5 ChartJob 实体（新增）

```swift
@objc(ChartJob)
public class ChartJob: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var chartId: UUID?
    @NSManaged public var recordingId: UUID
    @NSManaged public var jobType: Int16          // JobType rawValue
    @NSManaged public var status: Int16           // JobStatus rawValue
    @NSManaged public var progress: Int32         // 0-100
    @NSManaged public var inputData: String?      // JSON 序列化的输入
    @NSManaged public var startedAt: Date?
    @NSManaged public var completedAt: Date?
    @NSManaged public var errorMessage: String?
    @NSManaged public var createdAt: Date
}

enum ChartJobType: Int16 {
    case analyze = 0
    case generate = 1
    case render = 2
    case export = 3
}
```

### 5.6 数据库迁移

从 v1.0 到 v1.1 的迁移：

1. **Chart 表重构**：
   - 保留现有 `id`, `recordingId`, `chartType`, `mermaidDefinition`, `exportedImagePath`, `createdAt`
   - 新增字段：`summaryId`, `chartTypeConfidence`, `status`, `styleTheme`, `templateId`, `nodeCount`, `edgeCount`, `maxDepth`, `generationTimeMs`, `version`, `isUserEdited`, `parentChartId`, `exportedSVGPath`, `updatedAt`, `errorMessage`, `retryCount`
   - 删除字段：`sourceMarkdown`（迁移到 Summary 表关联）

2. **新增表**：
   - ChartNode、ChartEdge、ChartJob

3. **关系更新**：
   - Recording → Chart：一对多
   - Chart → ChartNode：一对多
   - Chart → ChartEdge：一对多

4. **索引**：
   - `idx_chart_recordingId_status`（查询某录音的所有已完成图表）
   - `idx_chartNode_chartId_sequence`
   - `idx_chartEdge_chartId_sourceNodeId`
   - `idx_chartJob_status`（查询待处理任务）

---

## 6. 非功能需求

### 6.1 性能需求

| 需求编号 | 需求描述 | 指标 | 测试条件 | 优先级 |
|----------|----------|------|----------|--------|
| CHT-PERF-001 | Agent 分析时间 | < 10 秒 | 标准会议纪要（500-2000 字），本地 LLM | P0 |
| CHT-PERF-002 | 渲染配置生成时间 | < 5 秒 | 从结构化数据到暗黑极客风 HTML/CSS + 渲染配置 JSON | P0 |
| CHT-PERF-003 | 端到端图表生成 | < 30 秒 | 从触发到渲染完成 | P0 |
| CHT-PERF-004 | 图表渲染时间 | < 3 秒 | WKWebView 初始化 + CSS 样式注入 + 图表渲染 | P0 |
| CHT-PERF-005 | 模板切换重渲染 | < 1 秒 | 同一图表切换不同模板 | P1 |
| CHT-PERF-006 | 导出 PNG 时间 | < 5 秒 | 1920x1080 分辨率 | P0 |
| CHT-PERF-007 | 导出 SVG 时间 | < 2 秒 | 标准尺寸 | P1 |
| CHT-PERF-008 | 编辑操作响应 | < 100ms | 节点增删改后渲染更新 | P1 |
| CHT-PERF-009 | 内存占用（图表渲染） | < 100MB | 含 WKWebView | P0 |
| CHT-PERF-010 | Python 运行时内存 | < 500MB | Agent 执行期间 | P0 |
| CHT-PERF-011 | 并发图表生成 | >= 2 个 | 同时处理 2 个录音的图表生成 | P2 |

### 6.2 兼容性需求

| 需求编号 | 需求描述 | 指标 | 优先级 |
|----------|----------|------|--------|
| CHT-COMP-001 | CSS 渲染引擎兼容 | WebKit 标准 CSS（渐变、毛玻璃、阴影） | P0 |
| CHT-COMP-002 | Python 版本兼容 | 支持 Python 3.10+ | P0 |
| CHT-COMP-003 | LangGraph 版本兼容 | 支持 LangGraph v0.1+ | P1 |
| CHT-COMP-004 | 图表 JSON 格式版本兼容 | v1.0 格式可导入 v1.1；渲染配置 JSON 含 style tokens 可跨版本解析 | P1 |

### 6.3 隐私需求

| 需求编号 | 需求描述 | 指标 | 优先级 |
|----------|----------|------|--------|
| CHT-SEC-001 | 原始音频不上传 | 音频文件仅本地存储 | P0 |
| CHT-SEC-002 | 转录文本脱敏 | 上传 Agent 的文本需去除敏感信息（人名可保留，公司机密信息需过滤） | P0 |
| CHT-SEC-003 | 本地运行优先 | Agent 默认在本地 Python 运行时执行，不依赖云端 | P0 |
| CHT-SEC-004 | 云端 LLM 可选 | 用户可选择使用云端 LLM 提升质量，需显式确认 | P1 |
| CHT-SEC-005 | 数据清除 | 图表数据随录音删除而删除 | P0 |

### 6.4 视觉一致性需求

| 需求编号 | 需求描述 | 指标 | 优先级 |
|----------|----------|------|--------|
| CHT-VIS-001 | 所有图表风格统一 | 不允许混合亮色/暗色风格；所有图表必须采用暗黑极客风设计系统 | P0 |
| CHT-VIS-002 | 配色符合设计系统 | 背景色 `#0F0F1A`、卡片色 `#1E1E2E`、边框色 `#33334D`、强调色使用 neon 色系（cyan/purple/orange/green/red/blue） | P0 |
| CHT-VIS-003 | 卡片圆角一致 | 所有容器卡片圆角为 16px，分层区块圆角为 12px | P0 |
| CHT-VIS-004 | 毛玻璃效果 | 导航/标题栏使用 `backdrop-filter: blur(12px)` + `rgba(15, 15, 26, 0.85)` 背景 | P1 |
| CHT-VIS-005 | 渐变文字效果 | 中心标题/大标题使用 `linear-gradient(135deg, #22D3EE, #8B5CF6)` + `-webkit-background-clip: text` | P1 |
| CHT-VIS-006 | 终端风格代码块 | 代码/日志展示使用 `#0A0A14` 背景 + 等宽字体 + 语法高亮 | P1 |
| CHT-VIS-007 | 悬浮阴影效果 | 卡片悬浮时显示 `0 12px 32px rgba(0,0,0,0.3)` 阴影 + `transform: translateY(-4px)` | P1 |
| CHT-VIS-008 | 左侧彩色边框标签 | tech-item 风格标签使用 3px 左侧彩色边框（状态对应颜色） | P1 |
| CHT-VIS-009 | 设计 Token 可覆盖 | 用户可在设置中自定义暗黑极客风设计 Token（颜色、圆角、阴影） | P2 |

### 6.5 可靠性需求

| 需求编号 | 需求描述 | 指标 | 优先级 |
|----------|----------|------|--------|
| CHT-REL-001 | Agent 崩溃恢复 | Python 进程崩溃后自动重启，重试当前任务 | P0 |
| CHT-REL-002 | 生成失败可重试 | 失败后保留输入数据，用户可手动重试 | P0 |
| CHT-REL-003 | 编辑数据不丢失 | 编辑操作实时保存，崩溃后可恢复 | P0 |
| CHT-REL-004 | 版本管理 | 保留 AI 原始版本，编辑不覆盖 | P1 |

---

## 7. 验收标准

### 7.1 功能验收清单

#### P0 功能

- [ ] **AC-CHT-001**：纪要生成完成后，Chart Agent 自动触发分析（延迟 < 5 秒）
- [ ] **AC-CHT-002**：Agent 能正确识别 6 大场景的内容特征并决策图表类型（测试用例覆盖）
- [ ] **AC-CHT-003**：思维导图正确反映纪要的层级结构（节点层级与原文一致）
- [ ] **AC-CHT-004**：流程图正确反映决策逻辑（无死路，条件分支完整）
- [ ] **AC-CHT-005**：时间线时间顺序正确，日期提取准确率 >= 90%
- [ ] **AC-CHT-006**：图表生成端到端时间 < 30 秒（标准纪要，本地运行）
- [ ] **AC-CHT-007**：支持导出 PNG（>= 144dpi）和 SVG 格式
- [ ] **AC-CHT-008**：图表支持缩放和平移交互
- [ ] **AC-CHT-009**：Chart Skill 接口可被纪要模块、历史模块调用
- [ ] **AC-CHT-010**：原始音频不上传，转录文本脱敏后处理
- [ ] **AC-CHT-011**：图表数据随录音删除而级联删除
- [ ] **AC-CHT-012**：WKWebView 本地渲染，无需网络即可查看图表
- [ ] **AC-CHT-013**：所有图表采用暗黑极客风视觉系统，配色符合设计 Token 规范
- [ ] **AC-CHT-014**：图表背景色为 `#0F0F1A`，卡片背景色为 `#1E1E2E`，卡片圆角为 16px
- [ ] **AC-CHT-015**：中心标题使用 cyan-purple 渐变文字效果
- [ ] **AC-CHT-016**：图表中不允许出现亮色/白色背景，视觉风格统一

#### P1 功能

- [ ] **AC-CHT-017**：流程图、时间线、看板生成可用（至少 3 种非思维导图类型）
- [ ] **AC-CHT-018**：支持节点增删改和撤销/重做
- [ ] **AC-CHT-019**：支持模板切换，样式实时更新
- [ ] **AC-CHT-020**：支持导出 JSON 可编辑格式和暗黑极客风 HTML 片段
- [ ] **AC-CHT-021**：图表生成过程显示进度条，支持取消
- [ ] **AC-CHT-022**：饼图/柱状图数值与原文一致
- [ ] **AC-CHT-023**：组织架构图人名提取准确率 >= 85%
- [ ] **AC-CHT-024**：看板待办事项完整无遗漏
- [ ] **AC-CHT-025**：毛玻璃效果在导航/标题栏正确渲染（`backdrop-filter: blur(12px)`）
- [ ] **AC-CHT-026**：终端风格代码块背景色为 `#0A0A14`，使用等宽字体
- [ ] **AC-CHT-027**：导出 HTML 文件可直接在浏览器打开并正确显示暗黑极客风样式

#### P2 功能

- [ ] **AC-CHT-028**：柱状图 SVG 原生渲染（WKWebView 性能不足时 fallback）
- [ ] **AC-CHT-029**：节点样式自定义（颜色、形状）
- [ ] **AC-CHT-030**：PDF 导出
- [ ] **AC-CHT-031**：图表关联音频时间戳跳转
- [ ] **AC-CHT-032**：用户可自定义暗黑极客风设计 Token（颜色、圆角、阴影）
- [ ] **AC-CHT-033**：设计 Token 自定义后所有图表实时更新样式

### 7.2 Agent 决策准确率验收

| 测试集 | 场景数量 | 准确率目标 | 测试方法 |
|--------|----------|-----------|----------|
| 会议结构脑图 | 20 | >= 85% | 人工判断图表类型是否匹配 |
| 决策流程图 | 15 | >= 80% | 人工判断流程逻辑是否正确 |
| 项目时间线 | 15 | >= 90% | 检查日期提取和时间顺序 |
| 数据对比图 | 10 | >= 85% | 检查数值一致性和图表类型选择 |
| 组织架构图 | 10 | >= 80% | 检查汇报关系和人名提取 |
| 看板 | 15 | >= 85% | 检查待办完整性和状态分类 |

### 7.3 Skill 接口验收

- [ ] **AC-SKILL-001**：Skill 接口定义稳定，输入/输出协议版本化
- [ ] **AC-SKILL-002**：Skill 可被至少 2 个内部模块调用（纪要模块 + 历史模块）
- [ ] **AC-SKILL-003**：Skill 配置参数热生效，无需重启应用
- [ ] **AC-SKILL-004**：Skill 执行失败返回标准错误码和可读错误信息

---

## 8. 里程碑与优先级

### 8.1 开发里程碑

| 里程碑 | 目标 | 周期 | 交付物 |
|--------|------|------|--------|
| **M4.1** | Chart Agent 基础架构 | 1.5 周 | Python 运行时集成、LangGraph 状态图骨架、Swift-Python 通信协议 |
| **M4.2** | 核心图表生成 + 暗黑极客风视觉系统 | 1.5 周 | 思维导图（P0）+ 流程图（P1）自动生成、WKWebView + 自定义 HTML/CSS 渲染、暗黑极客风 CSS 框架、Core Data 模型扩展 |
| **M4.3** | Skill 化封装 | 1 周 | Skill 协议定义、ChartSkill 实现（输出 HTML 片段 + 渲染配置 JSON）、模块间调用集成 |
| **M4.4** | 多图表类型扩展 | 1 周 | 时间线、看板、饼图、组织架构图，全部适配暗黑极客风 |
| **M4.5** | 交互与导出 | 1 周 | 节点编辑、模板系统（含暗黑极客风预设模板集）、PNG/SVG/JSON/暗黑极客风 HTML 导出 |
| **M4.6** | 验收与优化 | 1 周 | 准确率测试、性能优化、边界情况处理 |

**总周期**：约 6 周（可与 v1.0 M4 并行或接续）

### 8.2 优先级矩阵

| 功能模块 | P0 | P1 | P2 |
|----------|----|----|----|
| 智能图表分析引擎 | 文本分析、图表决策、思维导图渲染配置生成 | 多轮推理优化、辅助图表类型 | 自定义决策规则 |
| 图表类型 | 思维导图 | 流程图、时间线、看板、饼图 | 柱状图、组织架构图 |
| 渲染 | WKWebView + 自定义 HTML/CSS（暗黑极客风） | 模板切换、缩放平移、SVG fallback | 原生 Swift 渲染评估 |
| 编辑 | 无 | 节点增删改、撤销重做 | 样式自定义、拖拽布局、设计 Token 覆盖 |
| Skill 接口 | 协议定义、基础实现、纪要模块调用、HTML 片段输出 | 历史模块调用、配置管理、渲染配置 JSON | 第三方调用支持 |
| 导出 | PNG、SVG、暗黑极客风 HTML | JSON、Markdown | PDF、CSV |

### 8.3 风险与缓解

| 风险 | 可能性 | 影响 | 缓解措施 |
|------|--------|------|----------|
| LangGraph Python 与 Swift 集成复杂 | 高 | 高 | 优先在 M4.1 验证集成方案，预留 1 周缓冲 |
| 自定义 HTML/CSS 渲染复杂度 | 中 | 中 | 柱状图/看板准备 SVG 原生渲染方案作为 fallback；建立暗黑极客风 CSS 组件库降低实现成本 |
| Agent 决策准确率不达标 | 中 | 高 | 建立测试集持续调优 Prompt，提供用户手动选择兜底 |
| Python 运行时包体积过大 | 中 | 中 | 评估用户系统 Python 复用 vs 内嵌 Python 运行时 |
| WKWebView 渲染性能不足 | 低 | 中 | 节点数 > 50 时自动简化，P2 评估原生渲染 |
| 本地 LLM 质量不足 | 中 | 高 | 支持云端 LLM 可选，默认本地 + 云端降级方案 |

---

## 9. 待决策项

| 序号 | 决策项 | 当前状态 | 决策责任人 | 阻塞影响 |
|------|--------|----------|------------|----------|
| 1 | Python 运行时集成方案（子进程 / HTTP / XPC） | 待决策 | claude-cp-arch | M4.1 架构设计 |
| 2 | 本地 LLM 选型（llama.cpp / mlx / 其他） | 待决策 | claude-cp-arch | Agent 质量与隐私 |
| 3 | SVG 原生渲染 fallback 方案（柱状图/看板） | 待决策 | claude-cp-arch | M4.4 部分图表类型 |
| 6 | 暗黑极客风 CSS 组件库架构 | 待决策 | claude-cp-arch / claude-xd-lead | M4.2 视觉系统交付 |
| 4 | Skill 协议与现有模块的集成方式 | 待决策 | claude-cp-arch | M4.3 Skill 封装 |
| 5 | 图表编辑的拖拽布局实现方案 | 待决策 | claude-cp-arch / claude-xd-lead | M4.5 交互编辑 |

---

## 10. 附录

### 10.1 术语表

| 术语 | 定义 |
|------|------|
| Chart Agent | 基于 LangGraph 的智能图表分析引擎，自动决策图表类型并生成可视化 |
| Chart Skill | 图表生成能力的 Skill 化封装，遵循统一 Skill 协议 |
| 暗黑极客风（Dark Cyberpunk） | 视觉设计系统，以深色背景（`#0F0F1A`）、neon 强调色（cyan/purple/orange/green/red/blue）、毛玻璃效果、渐变文字、终端风格为特征 |
| 设计 Token | 可复用的视觉属性键值对（颜色、圆角、阴影、字体等），用于统一和自定义图表视觉风格 |
| WKWebView | macOS WebKit 浏览器控件，用于本地渲染自定义 HTML/CSS 图表内容 |
| LangGraph | Python 框架，用于构建有状态的多 Actor 应用（LLM Agent） |
| 脱敏 | 去除文本中的敏感信息（如公司机密、客户数据），保留结构化内容 |
| 置信度 | Agent 对图表类型决策的确信程度，0-1 之间 |

### 10.2 参考文档

- PRD-v1.0.md — 基础产品需求
- TechSpec-v1.0.md — 技术选型与架构
- DatabaseDesign-v1.0.md — 数据库设计
- UserStoriesUseCases-v1.0.md — 用户故事与用例
- NonFunctionalRequirements-v1.0.md — 非功能需求

### 10.3 文档变更记录

| 版本 | 日期 | 变更内容 | 作者 |
|------|------|----------|------|
| v1.1 | 2026/05/28 | 初始版本，基于 v1.0 第 4.4 节扩展 Chart Agent 完整 PRD；全面采用暗黑极客风（Dark Cyberpunk）视觉系统 | claude-cp-lead |
