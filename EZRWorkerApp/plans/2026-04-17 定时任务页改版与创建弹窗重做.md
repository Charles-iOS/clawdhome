# 定时任务页改版与创建弹窗重做

## Summary
- 将 `CronTaskView` 从当前的左右分栏改为“`PageHeroHeader` + 右上新建按钮 + 单列任务卡片列表”，整体视觉对齐参考图。
- 保留 `PageHeroHeader`，但在页面层用 `HStack` 包装 header 与右侧主操作按钮，因为 `PageHeroHeader` 本身不负责 actions。
- 创建任务改为自定义弹窗样式，视觉按图实现；本次先做“可用版”，提交仍只使用当前后端已支持字段，未接通能力用固定默认值或非交互占位。
- 任务详情不再常驻页面，改为点击任务卡片后以 sheet 打开现有详情视图，保留立即执行、删除、运行历史等能力。

## Implementation Changes
- `CronTaskView`
  - 用顶部 `HStack` 重组 hero 区：左侧 `PageHeroHeader`，右侧黑色胶囊“新建任务”按钮。
  - 移除 `HSplitView` 与 sidebar `List`，改为 `ScrollView`/`LazyVStack` 卡片流。
  - 空态、加载态保留，但样式调整到卡片流语境下。
  - 点击卡片时设置选中任务并弹出详情 sheet。
- 任务卡片
  - 新增卡片组件承载摘要信息：标题、简短描述/消息摘要、启用开关、调度文案、创建或下次执行时间。
  - 视觉对齐参考图：圆角白卡、轻描边、较宽留白、开关位于右上。
  - 卡片上的启停开关直接复用现有 `toggleEnabled` 能力；整卡点击进入详情。
  - 调度文案统一格式化：`cron` 显示更友好的文本，`every/at` 继续兼容现有模型。
- `CronAddSheet`
  - 从 `NavigationStack + Form` 改为自定义弹窗布局，包含标题、主要表单区、底部取消/创建操作区。
  - 字段布局按图组织：
    - 名称：真实可编辑并参与提交。
    - 发送到：显示“智能体 / 指定会话”分段，但本次固定默认到智能体主会话；若保留切换 UI，则未实现选项禁用或不暴露。
    - 智能体：本次使用默认 `"main"`，如果展示选择器则仅展示当前默认值，不引入未接通的数据源依赖。
    - 提示词：真实绑定到当前 `message`。
    - 调度：做成图中样式，但内部先映射到当前已支持的 `cronExpr`。
  - 创建提交仍生成当前 `GatewayCronAddParams`：
    - `sessionTarget = "main"`
    - `wakeMode = "now"`
    - `payload = .agentTurn(...)`
    - 调度先默认走 `schedule = .cron(...)`
  - 模板按钮本次仅做视觉入口；若无现成模板数据与行为，不接功能或置为禁用，避免假交互。
- `CronJobDetailView`
  - 保持核心能力不变，作为点击卡片后的详情 sheet 内容使用。
  - 如有必要，仅做弹窗尺寸和顶部信息微调，使其适配“从卡片进入”的使用方式。

## Public APIs / Types
- 不修改 `GatewayCronStore`、`GatewayCronJob`、`GatewayCronAddParams` 的对外接口。
- 本次不新增后端 RPC 字段，不扩展真实的会话选择、模板注入或非 cron 调度协议。
- 如果需要更友好的卡片摘要，可在视图层新增本地格式化 helpers，而不是改动模型层协议。

## Test Plan
- 页面加载时：
  - 已连接且有任务时显示卡片列表。
  - 加载中显示 progress。
  - 无任务时显示空态。
- 交互：
  - 点击“新建任务”能打开新的自定义弹窗。
  - 点击任务卡片能打开详情 sheet。
  - 卡片右上启停开关能切换状态并刷新显示。
- 创建任务：
  - 名称为空或提示词为空时禁用“创建”。
  - 输入名称、提示词、调度后可以成功创建，并自动选中新任务。
  - 创建失败时仍展示错误信息。
- 回归：
  - 详情中的立即执行、删除、运行历史刷新仍可用。
  - 现有 `GatewayCronStore.refresh/add/remove/run/toggleEnabled` 行为不受影响。

## Assumptions
- 主页面采用“卡片列表 + 点卡片弹详情”的新交互，不保留常驻右侧详情栏。
- 创建弹窗本次优先完成视觉与现有能力对齐，不补后端尚未接通的真实“智能体选择 / 指定会话 / 模板 / 单次-每天-间隔”完整能力。
- `PageHeroHeader` 继续原样复用，页面自行处理右上操作按钮布局。
