# 模型切换：从 TUI 自动化迁移到 --resume + --model 重启

**日期**: 2026-04-09
**状态**: 设计中

## 问题

当前 `claude.switch_model` 通过终端自动化操作 TUI 菜单（发送 `/model\n` → 等 1.2s → 读屏幕 → 解析菜单 → 发数字键）。这种方式脆弱且经常失败。

## 方案

杀掉当前 Claude Code 进程，用 `claude --resume <sessionId> --model <newModel>` 重新启动。JSONL 文件不变，消息历史完全保留。

## 架构

```
手机端                    Mac 端 (RelayBridge)                  终端 (Ghostty)
  │                              │                                  │
  │ claude.switch_model          │                                  │
  │ {surface_id, model}         │                                  │
  │─────────────────────────────>│                                  │
  │                              │                                  │
  │  ← RPC 响应 {ok, switching} │                                  │
  │<─────────────────────────────│                                  │
  │                              │                                  │
  │  ← pushEvent                 │                                  │
  │    "claude.model_switching"  │  1. 查 session ID               │
  │    {model: "sonnet"}         │  2. send_key ctrl-c              │
  │<─────────────────────────────│─────────────────────────────────>│ Claude 退出
  │                              │                                  │
  │  (手机显示切换动画)           │  3. 等待 shell prompt            │
  │  (输入框禁用)                │     (轮询 read_terminal_text)    │
  │                              │                                  │
  │                              │  4. send_text                    │
  │                              │   "claude --resume $SID          │
  │                              │    --model sonnet\n"             │
  │                              │─────────────────────────────────>│ Claude 启动
  │                              │                                  │
  │                              │  5. 等待 SessionStart hook       │
  │                              │     (hook 通知 cmux 新会话就绪)   │
  │                              │                                  │
  │  ← pushEvent                 │                                  │
  │    "claude.model_switched"   │                                  │
  │    {model: "sonnet", ok}     │                                  │
  │<─────────────────────────────│                                  │
  │                              │                                  │
  │  (恢复输入框)                │                                  │
```

## 详细设计

### 1. RPC 接口变更

`claude.switch_model` 的参数不变：
```json
{
  "surface_id": "xxx",
  "model": "sonnet"  // "default" | "sonnet" | "haiku" | "opus"
}
```

响应改为立即返回，切换结果通过事件推送：
```json
// 立即响应
{ "ok": true, "switching": true }

// 推送事件 1：开始切换
{ "event": "claude.model_switching", "payload": { "model": "sonnet" } }

// 推送事件 2：切换完成
{ "event": "claude.model_switched", "payload": { "model": "sonnet", "ok": true } }

// 推送事件 2（失败）：
{ "event": "claude.model_switched", "payload": { "model": "sonnet", "ok": false, "error": "..." } }
```

### 2. handleSwitchModel 重写

替换 `RelayBridge.swift` 中的 `handleSwitchModel()` 方法：

**步骤 1 — 查找 session ID**
- 调用 `lookupSessionId(forSurface:)` 从 `~/.cmuxterm/claude-hook-sessions.json` 获取
- 如果找不到，返回错误

**步骤 2 — 推送 "切换中" 事件**
- `pushEvent("claude.model_switching", payload: ["model": modelKey])`
- 手机端收到后禁用输入框，显示 "正在切换到 Sonnet..." 动画

**步骤 3 — 发送 Ctrl+C 终止 Claude Code**
- `sendJsonRPC(method: "surface.send_key", params: ["surface_id": surfaceID, "key": "ctrl-c"])`
- 如果 Claude 在等待输入（idle 状态），Ctrl+C 会直接退出
- 如果 Claude 在执行中，Ctrl+C 会中断并退出

**步骤 4 — 等待 shell prompt 出现**
- 轮询 `read_terminal_text`，检测 shell prompt 标志（`$`、`%`、`#`、`❯`）
- 超时 5 秒，每 300ms 检查一次
- 为什么不用固定延时：Claude 退出速度不确定，轮询更可靠

**步骤 5 — 映射 model key 到 CLI 参数**
- `"default"` → 不传 `--model`（使用默认）
- `"sonnet"` → `--model sonnet`
- `"haiku"` → `--model haiku`
- `"opus"` → `--model opus`

**步骤 6 — 发送重启命令**
```
claude --resume <sessionId> --model <modelKey>\n
```
- 通过 `surface.send_text` 发送到终端
- `claude` wrapper 检测到 `--resume` 参数会跳过注入 `--session-id`（已有逻辑，见 wrapper 第 176-184 行）

**步骤 7 — 等待新会话就绪**
- 轮询 `read_terminal_text`，检测 Claude Code 就绪标志（出现 `>` prompt 或消息输出）
- 超时 15 秒
- 或者：监听 SessionStart hook 回调（更可靠，但需要确认 hook 在 resume 时是否触发）

**步骤 8 — 推送 "切换完成" 事件**
- `pushEvent("claude.model_switched", payload: ["model": modelKey, "ok": true])`
- 手机端恢复输入框

**超时/失败处理：**
- 任何步骤超时 → 推送失败事件，手机端恢复输入框并显示错误提示
- Ctrl+C 后 shell 没出现 → 可能 Claude 没完全退出，再发一次 Ctrl+C
- 重启命令后超时 → 推送失败，用户可手动重试

### 3. model key 到 --model 参数映射

| 手机端 key | CLI 参数 | 说明 |
|-----------|---------|------|
| `"default"` | （不传 --model） | 使用 Claude Code 默认模型 |
| `"sonnet"` | `--model sonnet` | Claude Code 识别 "sonnet" 短名 |
| `"haiku"` | `--model haiku` | Claude Code 识别 "haiku" 短名 |
| `"opus"` | `--model opus` | Claude Code 识别 "opus" 短名 |

注：Claude Code 的 `--model` 参数支持短名（sonnet、haiku、opus）和完整模型 ID。短名更简洁且不会因版本更新失效。

### 4. claude wrapper 兼容性

当前 wrapper（`Resources/bin/claude`）已处理 `--resume` 参数：
```bash
for arg in "$@"; do
    case "$arg" in
        --resume|--resume=*|-r|--session-id|--session-id=*|--continue|-c)
            SKIP_SESSION_ID=true
            break
            ;;
    esac
done
```

当 `SKIP_SESSION_ID=true` 时，wrapper 不会注入 `--session-id`，但仍会注入 `--settings`（hooks）。这正是我们需要的行为：
- `--resume` 恢复原会话 → 消息历史不变
- `--settings` 注入 hooks → SessionStart 等 hook 正常触发
- `--model` 指定新模型 → 切换生效

### 5. JSONL 监听连续性

切换期间 JSONL 文件监听的处理：
- **不需要停止/重启监听**：`--resume` 继续写入同一个 JSONL 文件
- `startWatchingClaude` 已经在监听该文件的 `.write` 和 `.extend` 事件
- Claude Code 重启后写入新消息，DispatchSource 自动触发，手机端收到增量推送

### 6. 手机端交互

**切换中状态（收到 `claude.model_switching`）：**
- 输入框区域替换为状态条：`[进度动画] 正在切换到 Sonnet...`
- 聊天历史仍可滚动查看
- 禁止发送消息

**切换完成（收到 `claude.model_switched`，`ok: true`）：**
- 恢复输入框
- 底部显示淡出提示："已切换到 Sonnet"（2 秒后自动消失）

**切换失败（收到 `claude.model_switched`，`ok: false`）：**
- 恢复输入框
- 显示错误提示："模型切换失败，请重试"（带重试按钮）

### 7. 边界情况

| 场景 | 处理 |
|------|------|
| Claude 正在执行工具 | Ctrl+C 中断执行，Claude 退出，--resume 恢复时上下文完整 |
| Claude 在等待权限确认 | Ctrl+C 取消确认并退出 |
| 连续快速切换 | 加锁，前一次切换未完成时拒绝新请求，返回 `"error": "switch_in_progress"` |
| session ID 找不到 | 立即返回错误，不执行切换 |
| 切换到当前已激活的模型 | 仍执行切换（重启），保证行为一致 |
| wrapper 找不到 real claude | 终端会显示错误，轮询超时后推送失败事件 |

### 8. 文件变更清单

| 文件 | 变更 |
|------|------|
| `Sources/Relay/RelayBridge.swift` | 重写 `handleSwitchModel()`，改为 Ctrl+C → 等 prompt → 重启流程 |
| `Resources/bin/claude` | 无需修改（已支持 `--resume` + `--model`） |

手机端变更（不在此 spec 范围，但列出接口）：
- 处理 `claude.model_switching` 事件 → 显示切换动画
- 处理 `claude.model_switched` 事件 → 恢复/报错
- `claude.switch_model` RPC 响应从同步结果变为 `{ ok, switching }`
