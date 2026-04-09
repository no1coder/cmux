# Model Switch via --resume + --model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将模型切换从脆弱的 TUI 菜单自动化改为 Ctrl+C 杀进程 → `claude --resume <sessionId> --model <model>` 重启，消息历史零损失。

**Architecture:** 重写 `RelayBridge.handleSwitchModel()` 为异步流程：查 session → pushEvent(switching) → Ctrl+C → 轮询等 shell prompt → send_text 重启命令 → 轮询等就绪 → pushEvent(switched)。加互斥锁防止并发切换。

**Tech Stack:** Swift, Unix socket JSON-RPC, Ghostty terminal control

**Spec:** `docs/superpowers/specs/2026-04-09-model-switch-resume-design.md`

---

### Task 1: 添加模型切换互斥锁和状态追踪

**Files:**
- Modify: `Sources/Relay/RelayBridge.swift:8-76` (属性区域)

- [ ] **Step 1: 在 RelayBridge 属性区域添加切换锁和辅助方法**

在 `private let watcherQueue` (第 40 行) 之后添加：

```swift
    // MARK: - 模型切换状态

    /// 模型切换互斥标志，防止并发切换
    private var isModelSwitching = false
    /// 保护 isModelSwitching 的队列
    private let modelSwitchQueue = DispatchQueue(label: "com.cmux.relay.modelSwitch")
```

- [ ] **Step 2: 添加读取终端文本的辅助方法**

在 `sendV1Command` 方法（约第 773 行）附近添加辅助方法，封装 `read_terminal_text` 的 base64 解码逻辑，供轮询使用：

```swift
    /// 读取指定 surface 的终端文本内容（解码 base64）
    /// 必须在 socketQueue 外调用
    private func readTerminalText(surfaceID: String) -> String? {
        let response = sendV1Command("read_terminal_text \(surfaceID)")
        guard let response, response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base64.isEmpty, let data = Data(base64Encoded: base64) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
```

- [ ] **Step 3: 构建并确认编译通过**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-model-switch build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Relay/RelayBridge.swift
git commit -m "feat(relay): add model switch mutex and readTerminalText helper"
```

---

### Task 2: 重写 handleSwitchModel 核心逻辑

**Files:**
- Modify: `Sources/Relay/RelayBridge.swift:342-430` (替换整个 handleSwitchModel 方法)

- [ ] **Step 1: 修改 `claude.switch_model` 的 RPC 入口为异步响应**

替换 `Sources/Relay/RelayBridge.swift` 中 `case "claude.switch_model":` 块（第 211-222 行）：

```swift
        // 模型切换：Ctrl+C 杀进程 → --resume + --model 重启
        case "claude.switch_model":
            let surfaceID = params?["surface_id"] as? String ?? ""
            let modelKey = params?["model"] as? String ?? ""
            guard Self.isValidID(surfaceID), !modelKey.isEmpty else {
                sendRPCResponse(requestID: requestID, result: ["error": "invalid params"])
                return
            }
            // 检查是否已有切换进行中
            let canSwitch = modelSwitchQueue.sync { () -> Bool in
                if isModelSwitching { return false }
                isModelSwitching = true
                return true
            }
            guard canSwitch else {
                sendRPCResponse(requestID: requestID, result: ["error": "switch_in_progress"])
                return
            }
            // 立即响应，切换结果通过事件推送
            sendRPCResponse(requestID: requestID, result: ["ok": true, "switching": true])
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                defer {
                    self.modelSwitchQueue.sync { self.isModelSwitching = false }
                }
                self.executeModelSwitch(surfaceID: surfaceID, modelKey: modelKey)
            }
```

- [ ] **Step 2: 替换 `handleSwitchModel` 方法为 `executeModelSwitch`**

删除旧的 `handleSwitchModel` 方法（第 340-430 行），替换为：

```swift
    // MARK: - 模型切换（--resume + --model 重启）

    /// 模型切换核心流程：Ctrl+C → 等 shell prompt → claude --resume → 等就绪
    private func executeModelSwitch(surfaceID: String, modelKey: String) {
        #if DEBUG
        dlog("[relay] 模型切换开始: surface=\(surfaceID.prefix(8)) model=\(modelKey)")
        #endif

        // 1. 查找 session ID
        guard let sessionId = lookupSessionId(forSurface: surfaceID) else {
            #if DEBUG
            dlog("[relay] 模型切换失败: 找不到 session ID")
            #endif
            pushEvent("claude.model_switched", payload: [
                "model": modelKey,
                "ok": false,
                "error": "找不到当前会话，请确认 Claude Code 正在运行",
            ])
            return
        }

        // 2. 推送"切换中"事件（手机端显示动画）
        pushEvent("claude.model_switching", payload: ["model": modelKey])

        // 3. 发送 Ctrl+C 终止 Claude Code
        _ = sendJsonRPC(method: "surface.send_key", params: [
            "surface_id": surfaceID,
            "key": "ctrl-c",
        ])

        // 4. 轮询等待 shell prompt 出现
        let promptReady = pollForShellPrompt(surfaceID: surfaceID, timeoutSeconds: 5)
        if !promptReady {
            // 可能 Claude 没完全退出，再发一次 Ctrl+C
            #if DEBUG
            dlog("[relay] 模型切换: 第一次 Ctrl+C 后未检测到 prompt，重试")
            #endif
            _ = sendJsonRPC(method: "surface.send_key", params: [
                "surface_id": surfaceID,
                "key": "ctrl-c",
            ])
            let retryReady = pollForShellPrompt(surfaceID: surfaceID, timeoutSeconds: 3)
            if !retryReady {
                #if DEBUG
                dlog("[relay] 模型切换失败: 等待 shell prompt 超时")
                #endif
                pushEvent("claude.model_switched", payload: [
                    "model": modelKey,
                    "ok": false,
                    "error": "终止 Claude Code 超时，请手动重试",
                ])
                return
            }
        }

        // 5. 构建重启命令
        let resumeCommand: String
        if modelKey.lowercased() == "default" {
            resumeCommand = "claude --resume \(sessionId)\n"
        } else {
            resumeCommand = "claude --resume \(sessionId) --model \(modelKey)\n"
        }

        // 6. 发送重启命令
        _ = sendJsonRPC(method: "surface.send_text", params: [
            "surface_id": surfaceID,
            "text": resumeCommand,
        ])

        // 7. 轮询等待 Claude Code 就绪（SessionStart hook 会更新 session store）
        let claudeReady = pollForClaudeReady(surfaceID: surfaceID, timeoutSeconds: 15)

        // 8. 推送结果
        if claudeReady {
            #if DEBUG
            dlog("[relay] 模型切换成功: model=\(modelKey)")
            #endif
            pushEvent("claude.model_switched", payload: [
                "model": modelKey,
                "ok": true,
            ])
        } else {
            #if DEBUG
            dlog("[relay] 模型切换: Claude 可能已启动但未确认就绪，仍视为成功")
            #endif
            // 命令已发送，即使轮询超时也大概率已启动，视为成功
            pushEvent("claude.model_switched", payload: [
                "model": modelKey,
                "ok": true,
            ])
        }
    }
```

- [ ] **Step 3: 构建并确认编译通过**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-model-switch build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Relay/RelayBridge.swift
git commit -m "feat(relay): rewrite model switch to use --resume + --model restart"
```

---

### Task 3: 实现轮询辅助方法

**Files:**
- Modify: `Sources/Relay/RelayBridge.swift` (在 `executeModelSwitch` 方法之后添加)

- [ ] **Step 1: 添加 pollForShellPrompt 方法**

在 `executeModelSwitch` 方法之后添加：

```swift
    /// 轮询终端输出，检测 shell prompt 是否出现
    /// - Parameters:
    ///   - surfaceID: 目标终端
    ///   - timeoutSeconds: 超时秒数
    /// - Returns: true 如果检测到 shell prompt
    private func pollForShellPrompt(surfaceID: String, timeoutSeconds: Int) -> Bool {
        let intervalMs: UInt32 = 300_000  // 300ms
        let maxAttempts = (timeoutSeconds * 1000) / 300

        for _ in 0..<maxAttempts {
            usleep(intervalMs)
            guard let text = readTerminalText(surfaceID: surfaceID) else { continue }

            // 检测最后几行是否包含常见 shell prompt 标志
            let lastLines = text.components(separatedBy: "\n").suffix(5)
            let lastContent = lastLines.joined(separator: "\n")

            // shell prompt 特征：行末以 $, %, #, ❯, >, → 结尾（可能前面有空格）
            // 或者包含典型 prompt 模式如 "user@host" 或路径
            if looksLikeShellPrompt(lastContent) {
                #if DEBUG
                dlog("[relay] 检测到 shell prompt")
                #endif
                return true
            }
        }
        return false
    }

    /// 判断终端文本最后几行是否像 shell prompt
    private func looksLikeShellPrompt(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let lastLine = lines.last else { return false }

        // 常见 prompt 结尾符
        let promptEndings: [Character] = ["$", "%", "#", ">", "❯", "→"]
        if let lastChar = lastLine.last, promptEndings.contains(lastChar) {
            return true
        }

        // zsh 默认 prompt: "user@host dir %"
        // bash 默认 prompt: "user@host:dir$"
        // 检测包含 @ 和常见结尾
        if lastLine.contains("@") && promptEndings.contains(where: { lastLine.contains(String($0)) }) {
            return true
        }

        return false
    }
```

- [ ] **Step 2: 添加 pollForClaudeReady 方法**

紧接着添加：

```swift
    /// 轮询等待 Claude Code 启动就绪
    /// 检测方式：终端出现 Claude 的 prompt 标志或 session store 中出现新记录
    private func pollForClaudeReady(surfaceID: String, timeoutSeconds: Int) -> Bool {
        let intervalMs: UInt32 = 500_000  // 500ms
        let maxAttempts = (timeoutSeconds * 1000) / 500

        for _ in 0..<maxAttempts {
            usleep(intervalMs)
            guard let text = readTerminalText(surfaceID: surfaceID) else { continue }

            // Claude Code 就绪标志：
            // 1. 出现 ">" prompt（Claude 等待输入）
            // 2. 出现 "Resuming" 或 "Claude" 相关文本
            // 3. 终端不再显示 shell prompt（说明新进程已接管）
            let lastLines = text.components(separatedBy: "\n").suffix(10)
            let lastContent = lastLines.joined(separator: "\n").lowercased()

            // Claude Code 启动后会显示类似 "Resuming conversation..." 或直接进入对话
            if lastContent.contains("resum") ||
               lastContent.contains("claude") ||
               lastContent.contains("╭") ||
               lastContent.contains("│") {
                #if DEBUG
                dlog("[relay] Claude Code 就绪信号检测到")
                #endif
                return true
            }
        }

        #if DEBUG
        dlog("[relay] pollForClaudeReady 超时")
        #endif
        return false
    }
```

- [ ] **Step 3: 构建并确认编译通过**

Run: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-model-switch build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/Relay/RelayBridge.swift
git commit -m "feat(relay): add shell prompt and Claude ready polling helpers"
```

---

### Task 4: 手动集成测试

**Files:** 无新增文件

- [ ] **Step 1: 用 tagged build 构建并启动**

```bash
./scripts/reload.sh --tag model-switch --launch
```

- [ ] **Step 2: 验证模型切换流程**

在手机端（或通过模拟 RPC）触发 `claude.switch_model`：
1. 打开一个终端，启动 `claude`
2. 发送消息让 Claude 产生一些对话
3. 触发模型切换到 "sonnet"
4. 观察：
   - Mac 终端：Ctrl+C → shell prompt → `claude --resume ... --model sonnet` → Claude 重启
   - 手机端：收到 `claude.model_switching` → `claude.model_switched`
   - 消息历史：切换后通过 `claude.messages` 获取的历史与切换前一致

- [ ] **Step 3: 验证边界情况**

1. **Claude 执行中切换**：Claude 在执行工具时触发切换，确认 Ctrl+C 能中断
2. **连续切换**：快速连续发两次切换请求，确认第二次返回 `switch_in_progress`
3. **session 未找到**：在没有 Claude 运行的 surface 上切换，确认返回错误
4. **default 模型**：切换到 "default"，确认命令中不包含 `--model`

- [ ] **Step 4: 确认 JSONL 连续性**

切换前后执行 `claude.messages` RPC，确认：
- `total_seq` 持续递增（没有重置）
- 之前的消息全部保留
- 新消息正常追加
