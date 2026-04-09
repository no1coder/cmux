import Bonsplit
import Foundation

// MARK: - RelayBridge

/// 将 WebSocket 消息桥接到本地 cmux Unix socket（JSON-RPC）
/// 负责：解析 Relay Envelope → 转发到本地 socket → 包装响应回传
final class RelayBridge {

    // MARK: - 属性

    /// 本地 cmux Unix socket 路径
    let socketPath: String

    /// 关联的 RelayClient（用于推送事件到手机端）
    weak var relayClient: RelayClient?

    /// 代理审批路由器（处理 agent.approve / agent.reject 消息）
    var agentApproval: RelayAgentApproval?

    /// 文件操作处理器（处理 file.list / file.read 消息）
    var fileHandler: RelayFileHandler?

    /// 浏览器操作处理器（处理 browser.screenshot 消息）
    var browserHandler: RelayBrowserHandler?

    /// E2E 加密管理器（可选：nil 时不加密，兼容旧版本）
    var e2eCrypto: RelayE2ECrypto?

    /// 混合消息处理器（手机发图片 + 文字到终端）
    lazy var composedMessageHandler = RelayComposedMessageHandler(bridge: self)

    // MARK: - JSONL 文件监听（轮询→推送）

    /// 当前监听的 JSONL 文件路径 → (fileDescriptor, dispatchSource, lastFileSize)
    private var jsonlWatchers: [String: (fd: Int32, source: DispatchSourceFileSystemObject, lastSize: UInt64)] = [:]
    /// surfaceID → 正在监听的 JSONL 路径
    private var watchedSurfaces: [String: String] = [:]
    /// 监听相关操作的串行队列
    private let watcherQueue = DispatchQueue(label: "com.cmux.relay.jsonlWatcher")

    // MARK: - 模型切换状态

    /// 模型切换互斥标志，防止并发切换
    private var isModelSwitching = false
    /// 保护 isModelSwitching 的队列
    private let modelSwitchQueue = DispatchQueue(label: "com.cmux.relay.modelSwitch")

    // MARK: - 持久化 Socket 连接

    /// 复用的 Unix socket 文件描述符，避免每次 RPC 都重新建连
    private var persistentFd: Int32?
    /// 保护 persistentFd 的串行队列
    private let socketQueue = DispatchQueue(label: "com.cmux.relay.socket")

    // MARK: - 安全：RPC 方法白名单

    /// 允许手机端通过 relay 转发到本地 socket 的方法白名单
    /// 不在此列表中的方法将被拒绝，防止任意命令执行
    private static let allowedForwardMethods: Set<String> = [
        // 终端输入
        "surface.send_text", "surface.send_key",
        // Surface 操作
        "surface.focus", "surface.current",
        // Workspace 导航
        "workspace.select", "workspace.next", "workspace.previous",
        "workspace.last", "workspace.current",
        // Pane 操作
        "pane.focus", "pane.last",
    ]

    /// surfaceID/sessionId 格式验证：严格 UUID 格式或纯十六进制+连字符
    static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 36 else { return false }
        // 严格限制为 UUID 字符：十六进制数字 + 连字符
        return id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    // MARK: - 初始化

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - 入站消息处理（手机 → Mac）

    /// 处理来自 RelayClient 的原始 Data（Relay Envelope 格式）
    /// Envelope 格式：{ seq, ts, from, type, payload }
    func handleIncoming(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if DEBUG
            dlog("[relay] handleIncoming: JSON 解析失败")
            #endif
            return
        }
        // 解析 Envelope 字段
        let msgType = envelope["type"] as? String ?? ""
        #if DEBUG
        dlog("[relay] handleIncoming: type=\(msgType)")
        #endif
        let seq = envelope["seq"] as? UInt64 ?? 0

        // 提取 payload（RPC 请求的实际内容）
        guard let rawPayload = envelope["payload"] as? [String: Any] else {
            // 非 RPC 消息（如 resume），忽略
            return
        }

        // E2E 解密：已配对时强制要求加密格式，拒绝明文
        let payload: [String: Any]
        if let crypto = e2eCrypto {
            // 已启用 E2E 加密，必须是加密格式
            guard RelayE2ECrypto.isEncrypted(rawPayload) else {
                #if DEBUG
                dlog("[relay] handleIncoming: 拒绝未加密的 payload（E2E 已启用）")
                #endif
                return
            }
            guard let decrypted = crypto.decrypt(rawPayload) else {
                #if DEBUG
                dlog("[relay] handleIncoming: E2E 解密失败")
                #endif
                return
            }
            payload = decrypted
        } else {
            // 未启用 E2E，接受明文
            payload = rawPayload
        }

        let method = payload["method"] as? String ?? ""
        let params = payload["params"] as? [String: Any]
        // 请求 ID（优先使用 payload 中的 id，兼容不同格式）
        let requestID = payload["id"] as? Int ?? Int(seq)

        #if DEBUG
        dlog("[relay] RPC method='\(method)' id=\(requestID) payload.keys=\(payload.keys.sorted())")
        #endif

        switch msgType {
        case "rpc_request":
            handleRPCRequest(method: method, params: params, requestID: requestID)
        default:
            // 其他消息类型（resume 等由 relay 服务器处理）
            break
        }
    }

    // MARK: - RPC 请求路由

    /// 根据 method 路由到不同处理器
    private func handleRPCRequest(method: String, params: [String: Any]?, requestID: Int) {
        switch method {
        // Agent 审批
        case "agent.approve", "agent.reject":
            let approved = method == "agent.approve"
            let approvalRequestID = params?["request_id"] as? String ?? ""
            agentApproval?.handleApprovalResponse(requestID: approvalRequestID, approved: approved)
            sendRPCResponse(requestID: requestID, result: ["ok": true])

        // 文件操作
        case "file.list", "file.read":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let result = self.handleLocalMethod(method: method, params: params)
                self.sendRPCResponse(requestID: requestID, result: result)
            }

        // 浏览器截图
        case "browser.screenshot":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let result = self.handleLocalMethod(method: method, params: params)
                self.sendRPCResponse(requestID: requestID, result: result)
            }

        // surface.list 拦截：遍历所有 workspace 获取完整列表
        case "surface.list":
            #if DEBUG
            dlog("[relay] surface.list 拦截, requestID=\(requestID)")
            #endif
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let allSurfaces = self.collectAllSurfaces()
                #if DEBUG
                dlog("[relay] surface.list 完成, 共 \(allSurfaces.count) 个 surface")
                #endif
                self.sendRPCResponse(requestID: requestID, result: ["surfaces": allSurfaces])
            }

        // 状态变更命令：执行后推送更新的 surface 列表
        case "workspace.create", "workspace.close",
             "surface.close", "surface.create", "surface.split",
             "pane.create", "pane.close", "pane.break", "pane.join":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.forwardToSocket(method: method, params: params, requestID: requestID)
                // 状态变更后推送更新的 surface 列表
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                    self.pushSurfaceList()
                }
            }

        // V1 文本命令（read_screen 不支持 JSON-RPC，需要用 V1 协议）
        case "read_screen":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let surfaceID = params?["surface_id"] as? String ?? ""
                // 安全：验证 surfaceID 格式，防止 V1 命令注入
                guard Self.isValidID(surfaceID) else {
                    self.sendRPCResponse(requestID: requestID, result: ["error": "invalid surface_id format"])
                    return
                }
                self.handleReadScreen(surfaceID: surfaceID, requestID: requestID)
            }

        // 模型切换：Ctrl+C 杀进程 → --resume + --model 重启
        case "claude.switch_model":
            let surfaceID = params?["surface_id"] as? String ?? ""
            let modelKey = params?["model"] as? String ?? ""
            // modelKey 白名单校验：只允许字母、数字、连字符、点，防止命令注入
            let modelKeyValid = !modelKey.isEmpty && modelKey.count <= 100
                && modelKey.range(of: #"^[a-zA-Z0-9.\-]+$"#, options: .regularExpression) != nil
            guard Self.isValidID(surfaceID), modelKeyValid else {
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

        // Claude 会话监听：手机进入聊天时开始，离开时停止
        case "claude.watch":
            let surfaceID = params?["surface_id"] as? String ?? ""
            guard Self.isValidID(surfaceID) else {
                sendRPCResponse(requestID: requestID, result: ["error": "invalid surface_id"])
                return
            }
            startWatchingClaude(surfaceID: surfaceID)
            sendRPCResponse(requestID: requestID, result: ["ok": true])

        case "claude.unwatch":
            let surfaceID = params?["surface_id"] as? String ?? ""
            stopWatchingClaude(surfaceID: surfaceID)
            sendRPCResponse(requestID: requestID, result: ["ok": true])

        // Claude JSONL 消息读取（直接从 Claude Code 会话文件读取，不解析终端）
        case "claude.messages":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let surfaceID = params?["surface_id"] as? String ?? ""
                guard Self.isValidID(surfaceID) else {
                    self.sendRPCResponse(requestID: requestID, result: ["error": "invalid surface_id format"])
                    return
                }
                let afterSeq = params?["after_seq"] as? Int ?? 0
                let result = self.readClaudeMessages(surfaceID: surfaceID, afterSeq: afterSeq)
                self.sendRPCResponse(requestID: requestID, result: result)
            }

        // 混合消息（手机发图片+文字到终端）
        case "composed_msg.start", "composed_msg.block", "composed_msg.end":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let result = self.composedMessageHandler.handleRPC(method: method, params: params)
                self.sendRPCResponse(requestID: requestID, result: result)
            }

        // 白名单内的方法：转发到本地 socket
        default:
            guard Self.allowedForwardMethods.contains(method) else {
                sendRPCResponse(requestID: requestID, result: ["error": "method_not_allowed: \(method)"])
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.forwardToSocket(method: method, params: params, requestID: requestID)
            }
        }
    }

    // MARK: - 转发到本地 Socket

    /// 内部直接调用的递增 RPC ID（从 90000 起，避免与普通 RPC id 冲突）
    private static var nextDirectID: Int = 90000

    /// 转发到本地 socket（不等待响应，供内部模块调用）
    func forwardToSocketDirect(method: String, params: [String: Any]) {
        Self.nextDirectID += 1
        let rpcRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": Self.nextDirectID,
            "params": params,
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: rpcRequest),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        _ = sendToUnixSocket(jsonString)
    }

    /// 将 RPC 请求转发到本地 cmux Unix socket，返回结果
    /// V2 JSON-RPC 方法内部通过 surface_id 自动定位 workspace，无需手动切换
    private func forwardToSocket(method: String, params: [String: Any]?, requestID: Int) {
        // 构造 JSON-RPC 请求
        var rpcRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": requestID,
        ]
        if let params {
            rpcRequest["params"] = params
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: rpcRequest),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            sendRPCResponse(requestID: requestID, result: ["error": "请求序列化失败"])
            return
        }

        // 发送到 Unix socket
        guard let responseString = sendToUnixSocket(jsonString) else {
            sendRPCResponse(requestID: requestID, result: ["error": "socket 通信失败"])
            return
        }

        // 解析响应
        if let responseData = responseString.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            // JSON-RPC 响应可能有 result 或 error 字段
            if let result = parsed["result"] {
                sendRPCResponse(requestID: requestID, result: ["result": result])
            } else if let error = parsed["error"] {
                sendRPCResponse(requestID: requestID, result: ["error": error])
            } else {
                sendRPCResponse(requestID: requestID, result: parsed)
            }
        } else {
            // V1 协议文本响应
            sendRPCResponse(requestID: requestID, result: ["text": responseString])
        }
    }

    // MARK: - V1 命令处理

    /// 通过 V1 文本协议读取终端屏幕内容
    // MARK: - 模型切换（--resume + --model 重启）

    /// 模型切换核心流程：Ctrl+C → 等 shell prompt → claude --resume → 等就绪
    private func executeModelSwitch(surfaceID: String, modelKey: String) {
        #if DEBUG
        dlog("[relay] 模型切换开始: surface=\(surfaceID.prefix(8)) model=\(modelKey)")
        #endif

        // 1. 查找 session ID 并校验格式
        guard let sessionId = lookupSessionId(forSurface: surfaceID),
              Self.isValidID(sessionId) else {
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

        // 3. 退出 Claude Code
        // 如果 Claude 在执行中，先 Ctrl+C 中断，再 /exit
        // 如果 Claude 在 idle，直接 /exit 即可（Ctrl+C 在 idle 下被忽略）
        _ = sendJsonRPC(method: "surface.send_key", params: [
            "surface_id": surfaceID,
            "key": "ctrl-c",
        ])
        Thread.sleep(forTimeInterval: 0.3)
        _ = sendJsonRPC(method: "surface.send_text", params: [
            "surface_id": surfaceID,
            "text": "/exit\n",
        ])

        // 4. 等待 Claude Code 退出并回到 shell
        // Ghostty shell integration 会检测 promptIdle，日志显示 /exit 后约 1 秒回到 prompt
        Thread.sleep(forTimeInterval: 2.0)
        #if DEBUG
        dlog("[relay] 模型切换: /exit 已发送，等待 2 秒后继续")
        #endif

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

        // 7. 轮询等待 Claude Code 就绪
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

    /// 轮询等待 Claude Code 启动就绪
    /// 先等 2 秒让进程启动（跳过命令回显），再检测 Claude TUI 特征
    private func pollForClaudeReady(surfaceID: String, timeoutSeconds: Int) -> Bool {
        // 先等 2 秒，跳过命令回显阶段（回显包含 "claude" 会导致误判）
        usleep(2_000_000)
        let remainingSeconds = max(timeoutSeconds - 2, 3)
        let intervalMs: UInt32 = 500_000  // 500ms
        let maxAttempts = (remainingSeconds * 1000) / 500

        // 记录初始终端内容用于变化检测
        let initialText = readTerminalText(surfaceID: surfaceID) ?? ""

        for _ in 0..<maxAttempts {
            usleep(intervalMs)
            guard let text = readTerminalText(surfaceID: surfaceID) else { continue }

            // 终端内容与初始快照不同，说明有新输出（Claude 正在启动）
            guard text != initialText else { continue }

            let lastLines = text.components(separatedBy: "\n").suffix(10)
            let lastContent = lastLines.joined(separator: "\n")

            // Claude Code TUI 就绪信号：
            // - 出现 box-drawing 边框（╭╮╰╯）表示 TUI 已渲染
            // - 不再是 shell prompt（说明新进程已接管终端）
            let hasBoxDrawing = lastContent.contains("╭") || lastContent.contains("╰")
            let noShellPrompt = !looksLikeShellPrompt(lastContent)

            if hasBoxDrawing && noShellPrompt {
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

    /// 如果目标 surface 不在当前 workspace，先自动切换
    /// 优先使用 read_terminal_text（单行 base64 响应），不支持时回退到 read_screen
    /// 所有 socket 操作在一个 socketQueue.sync 块内完成，避免重入死锁
    private func handleReadScreen(surfaceID: String, requestID: Int) {
        guard !surfaceID.isEmpty else {
            sendRPCResponse(requestID: requestID, result: ["error": "缺少 surface_id"])
            return
        }

        // 统一在 socketQueue 内执行所有 socket 操作，使用 _unsafe 方法避免重入
        let result: [String: Any] = socketQueue.sync {
            // 优先尝试 read_terminal_text（单行 "OK {base64}" 响应）
            var response = _sendV1CommandUnsafe("read_terminal_text \(surfaceID)")

            // 如果命令不存在（旧版守护进程），回退到 read_screen
            let useBase64: Bool
            if let resp = response, resp.contains("Unknown command") {
                useBase64 = false
                response = _sendV1CommandUnsafe("read_screen \(surfaceID)")
            } else {
                useBase64 = true
            }

            if response == nil || response?.hasPrefix("ERROR") == true {
                // 尝试切换到 surface 所在的 workspace 后重试
                if _switchToWorkspaceContainingUnsafe(surfaceID: surfaceID) {
                    response = _sendV1CommandUnsafe(useBase64
                        ? "read_terminal_text \(surfaceID)"
                        : "read_screen \(surfaceID)")
                }
            }

            guard let response, !response.hasPrefix("ERROR") else {
                return ["error": response ?? "socket 通信失败"]
            }

            let lines: [String]
            if useBase64 {
                guard response.hasPrefix("OK ") else {
                    return ["error": "unexpected response: \(response.prefix(100))"]
                }
                let base64Payload = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !base64Payload.isEmpty, let data = Data(base64Encoded: base64Payload) {
                    lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                } else {
                    lines = []
                }
            } else {
                lines = response.components(separatedBy: "\n")
            }

            return ["lines": lines, "surface_id": surfaceID]
        }

        sendRPCResponse(requestID: requestID, result: result)
    }

    /// 切换到包含指定 surface 的 workspace（不持锁版本，必须在 socketQueue 内调用）
    private func _switchToWorkspaceContainingUnsafe(surfaceID: String) -> Bool {
        guard let wsResp = _sendJsonRPCUnsafe(method: "workspace.list", params: nil),
              let wsResult = wsResp["result"] as? [String: Any],
              let workspaces = wsResult["workspaces"] as? [[String: Any]] else {
            return false
        }

        for ws in workspaces {
            guard let wsID = ws["id"] as? String,
                  (ws["selected"] as? Bool) != true else { continue }

            if let surfResp = _sendJsonRPCUnsafe(method: "surface.list", params: ["workspace_id": wsID]),
               let surfResult = surfResp["result"] as? [String: Any],
               let surfaces = surfResult["surfaces"] as? [[String: Any]],
               surfaces.contains(where: { ($0["id"] as? String) == surfaceID }) {
                _ = _sendJsonRPCUnsafe(method: "workspace.select", params: ["workspace_id": wsID])
                #if DEBUG
                dlog("[relay] 切换到 workspace \(wsID.prefix(8))... 以操作 surface \(surfaceID.prefix(8))...")
                #endif
                return true
            }
        }
        return false
    }

    /// 外部调用版本（自动加锁）
    private func switchToWorkspaceContaining(surfaceID: String) -> Bool {
        return socketQueue.sync {
            _switchToWorkspaceContainingUnsafe(surfaceID: surfaceID)
        }
    }

    // MARK: - 响应发送

    /// 发送 RPC 响应（Envelope 格式）回手机端
    private func sendRPCResponse(requestID: Int, result: [String: Any]) {
        #if DEBUG
        dlog("[relay] sendRPCResponse id=\(requestID) keys=\(result.keys.sorted()) client=\(relayClient != nil) connected=\(relayClient?.status == .connected)")
        #endif
        var responsePayload = result
        responsePayload["id"] = requestID

        // E2E 加密：如果配置了加密管理器，则加密 payload
        let finalPayload: [String: Any]
        if let crypto = e2eCrypto, let encrypted = crypto.encrypt(responsePayload) {
            finalPayload = encrypted
        } else {
            finalPayload = responsePayload
        }

        let envelope: [String: Any] = [
            "seq": 0,
            "ts": Int64(Date().timeIntervalSince1970),
            "from": "mac",
            "type": "rpc_response",
            "payload": finalPayload,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return
        }
        relayClient?.send(data)
    }

    // MARK: - 出站事件推送（Mac → iOS）

    /// 推送 Mac 端产生的事件到手机（Envelope 格式）
    /// - Parameters:
    ///   - eventType: 事件类型
    ///   - payload: 事件数据
    ///   - pushHint: APNs 离线推送提示（E2E 加密时 Relay 无法读取 payload，需要明文 hint）
    func pushEvent(_ eventType: String, payload: [String: Any], pushHint: [String: String]? = nil) {
        #if DEBUG
        dlog("[relay] pushEvent: \(eventType), relayClient=\(relayClient != nil)")
        #endif
        var eventPayload = payload
        eventPayload["event"] = eventType

        // E2E 加密：如果配置了加密管理器，则加密 payload
        let finalPayload: [String: Any]
        if let crypto = e2eCrypto, let encrypted = crypto.encrypt(eventPayload) {
            finalPayload = encrypted
        } else {
            finalPayload = eventPayload
        }

        var envelope: [String: Any] = [
            "seq": 0,
            "ts": Int64(Date().timeIntervalSince1970),
            "from": "mac",
            "type": "event",
            "payload": finalPayload,
        ]

        // 添加明文 push_hint（用于 Relay 在手机离线时决定是否发送 APNs）
        if let pushHint {
            envelope["push_hint"] = pushHint
        }

        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return
        }
        relayClient?.send(data)
    }

    /// 推送所有 workspace 的 surface 列表到手机端
    func pushSurfaceList() {
        #if DEBUG
        dlog("[relay] pushSurfaceList 被调用")
        #endif
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let allSurfaces = self.collectAllSurfaces()
            #if DEBUG
            dlog("[relay] pushSurfaceList: 共 \(allSurfaces.count) 个 surface")
            #endif
            self.pushEvent("surface.list_update", payload: ["surfaces": allSurfaces])
        }
    }

    /// 收集所有 workspace 的 surfaces
    /// 注意：使用 workspace_id 参数直接查询，不切换当前 workspace，避免 UI 卡顿
    private func collectAllSurfaces() -> [[String: Any]] {
        guard let wsResp = sendJsonRPC(method: "workspace.list", params: nil),
              let wsResult = wsResp["result"] as? [String: Any],
              let workspaces = wsResult["workspaces"] as? [[String: Any]] else {
            return []
        }

        var allSurfaces: [[String: Any]] = []

        for ws in workspaces {
            guard let wsID = ws["id"] as? String else { continue }
            let wsTitle = ws["title"] as? String ?? ""
            let wsCwd = ws["current_directory"] as? String ?? ""
            let wsName = wsCwd.isEmpty ? wsTitle : wsCwd

            // 使用 workspace_id 参数直接查询，不需要 workspace.select
            if let surfResp = sendJsonRPC(method: "surface.list", params: ["workspace_id": wsID]),
               let surfResult = surfResp["result"] as? [String: Any],
               let surfaces = surfResult["surfaces"] as? [[String: Any]] {
                for var surf in surfaces {
                    surf["workspace_id"] = wsID
                    surf["workspace_name"] = wsName
                    allSurfaces.append(surf)
                }
            }
        }

        return allSurfaces
    }

    /// 发送 JSON-RPC 请求并返回解析后的响应（自动加锁）
    private func sendJsonRPC(method: String, params: [String: Any]?) -> [String: Any]? {
        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": Int(Date().timeIntervalSince1970 * 1000) % 1_000_000,
        ]
        if let params { request["params"] = params }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8),
              let response = sendToUnixSocket(jsonString),
              let responseData = response.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    /// 不持锁版本，供已在 socketQueue 内的代码调用
    private func _sendJsonRPCUnsafe(method: String, params: [String: Any]?) -> [String: Any]? {
        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": Int(Date().timeIntervalSince1970 * 1000) % 1_000_000,
        ]
        if let params { request["params"] = params }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8),
              let response = _sendToUnixSocketUnsafe(jsonString),
              let responseData = response.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    /// 推送 workspace 列表到手机端
    func pushWorkspaceList() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "workspace.list",
                "id": 2,
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
                  let jsonString = String(data: jsonData, encoding: .utf8),
                  let response = self.sendToUnixSocket(jsonString),
                  let responseData = response.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let result = parsed["result"] else {
                return
            }

            self.pushEvent("workspace.list_update", payload: ["workspaces": result])
        }
    }

    // MARK: - 本地方法路由

    /// 路由文件/浏览器操作方法到对应处理器
    private func handleLocalMethod(method: String, params: [String: Any]?) -> [String: Any] {
        switch method {
        case "file.list":
            guard let path = params?["path"] as? String else {
                return ["error": "缺少 path 参数"]
            }
            guard let handler = fileHandler else {
                return ["error": "文件处理器未初始化"]
            }
            do {
                return try handler.listDirectory(path: path)
            } catch let error as FileSandboxError {
                return ["error": sandboxErrorMessage(error)]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "file.read":
            guard let path = params?["path"] as? String else {
                return ["error": "缺少 path 参数"]
            }
            guard let handler = fileHandler else {
                return ["error": "文件处理器未初始化"]
            }
            do {
                return try handler.readFile(path: path)
            } catch let error as FileSandboxError {
                return ["error": sandboxErrorMessage(error)]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "browser.screenshot":
            guard let surfaceID = params?["surface_id"] as? String else {
                return ["error": "缺少 surface_id 参数"]
            }
            guard let handler = browserHandler else {
                return ["error": "浏览器处理器未初始化"]
            }
            return handler.captureScreenshot(surfaceID: surfaceID)

        default:
            return ["error": "未知方法: \(method)"]
        }
    }

    /// 将沙箱错误转换为用户友好的错误信息
    private func sandboxErrorMessage(_ error: FileSandboxError) -> String {
        switch error {
        case .pathOutsideAllowedRoot:
            return "路径不在允许的目录范围内"
        case .pathTraversal:
            return "路径包含非法的路径穿越字符"
        case .symbolicLinkEscape:
            return "符号链接目标超出允许的目录范围"
        case .sensitiveFile:
            return "拒绝访问敏感文件"
        case .fileNotFound:
            return "文件不存在"
        }
    }

    // MARK: - Unix Socket I/O

    /// 发送 V1 文本命令到本地 Unix socket，返回响应字符串
    /// 使用独立的一次性连接，避免多行响应（如 read_screen）污染持久化 socket 的接收缓冲区
    /// 注意：不可在 socketQueue.sync 内部调用，否则死锁
    func sendV1Command(_ command: String) -> String? {
        return socketQueue.sync {
            _sendV1CommandUnsafe(command)
        }
    }

    /// 读取指定 surface 的终端文本内容（解码 base64）
    /// 必须在 socketQueue 外调用
    private func readTerminalText(surfaceID: String) -> String? {
        let response = sendV1Command("read_terminal_text \(surfaceID)")
        guard let response, response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base64.isEmpty, let data = Data(base64Encoded: base64) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 不持锁版本，供已在 socketQueue 内的代码调用（如 handleReadScreen 的组合操作）
    private func _sendV1CommandUnsafe(_ command: String) -> String? {
        guard let fd = createConnection() else { return nil }
        defer { close(fd) }
        return sendAndRecv(fd: fd, json: command)
    }

    /// 发送 JSON 字符串到本地 Unix socket，返回响应字符串
    /// 内部复用持久化连接，发送失败时自动重连一次
    /// 注意：不可在 socketQueue.sync 内部调用，否则死锁
    func sendToUnixSocket(_ json: String) -> String? {
        return socketQueue.sync {
            _sendToUnixSocketUnsafe(json)
        }
    }

    /// 不持锁版本，供已在 socketQueue 内的代码调用
    private func _sendToUnixSocketUnsafe(_ json: String) -> String? {
        // 尝试用持久化连接发送
        if let fd = persistentFd, let result = sendAndRecv(fd: fd, json: json) {
            return result
        }
        // 持久化连接不可用或发送失败，重连
        closePersistentFd()
        guard let fd = createConnection() else { return nil }
        persistentFd = fd
        return sendAndRecv(fd: fd, json: json)
    }

    /// 创建新的 Unix socket 连接
    private func createConnection() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (i, byte) in pathBytes.enumerated() {
                ptr[i] = UInt8(bitPattern: byte)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(fd)
            return nil
        }

        // 设置 recv 超时（10 秒），防止 read_screen 等命令卡死线程
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        return fd
    }

    /// 在已连接的 fd 上发送 JSON 并读取响应
    private func sendAndRecv(fd: Int32, json: String) -> String? {
        let payload = json + "\n"
        guard let payloadData = payload.data(using: .utf8) else { return nil }

        let sendResult = payloadData.withUnsafeBytes { ptr in
            Foundation.send(fd, ptr.baseAddress!, ptr.count, 0)
        }
        guard sendResult == payloadData.count else {
            // 发送失败，标记连接已断开
            closePersistentFd()
            return nil
        }

        // 读取响应（增大缓冲区到 64KB）
        var responseBuffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 65536)

        while true {
            let bytesRead = recv(fd, &readBuf, readBuf.count, 0)
            if bytesRead <= 0 {
                // 连接已断开，清理持久化 fd
                closePersistentFd()
                if responseBuffer.isEmpty { return nil }
                break
            }
            responseBuffer.append(contentsOf: readBuf[..<bytesRead])
            if responseBuffer.contains(UInt8(ascii: "\n")) { break }
        }

        return String(data: responseBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .newlines)
    }

    /// 关闭持久化连接并清理 fd
    private func closePersistentFd() {
        if let fd = persistentFd {
            close(fd)
            persistentFd = nil
        }
    }

    /// 主动关闭持久化 socket 连接（供外部调用，如断开 relay 时）
    func closeSocket() {
        socketQueue.sync {
            closePersistentFd()
        }
    }

    // MARK: - Claude JSONL 消息读取

    /// 从 Claude Code 的 JSONL 会话文件读取结构化消息
    /// 跟 happy 项目的 sessionScanner 一样，直接读文件而非解析终端
    /// Claude 项目数据的安全基础路径
    private static var claudeProjectsBase: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
    }

    /// 检测系统注入的 user 消息（skill 展开、任务通知、命令输出等），这些不应显示在手机端
    private static func isSystemInjectedUserMessage(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any] else { return false }
        let content = message["content"]

        // 提取文本内容
        var text = ""
        if let str = content as? String {
            text = str
        } else if let blocks = content as? [[String: Any]] {
            // 只检查第一个 text block
            for block in blocks {
                if (block["type"] as? String) == "text", let t = block["text"] as? String {
                    text = t
                    break
                }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Skill 展开内容
        if trimmed.hasPrefix("Base directory for this skill:") { return true }
        // 系统 XML 标签注入
        let systemPrefixes = [
            "<task-notification>",
            "<command-name>",
            "<local-command-caveat>",
            "<local-command-stdout>",
            "<local-command-stderr>",
            "<system-reminder>",
        ]
        for prefix in systemPrefixes {
            if trimmed.hasPrefix(prefix) { return true }
        }
        return false
    }

    private func readClaudeMessages(surfaceID: String, afterSeq: Int) -> [String: Any] {
        // 1. 先从 session store 精确匹配 surfaceId → sessionId
        let jsonlPath: String
        if let sessionId = lookupSessionId(forSurface: surfaceID) {
            // 安全：验证 sessionId 格式（UUID 字符）
            guard Self.isValidID(sessionId) else {
                return ["error": "invalid session_id format", "messages": []]
            }
            let cwd = getSurfaceCwd(surfaceID: surfaceID) ?? ""
            let projectDir = claudeProjectPath(forCwd: cwd)
            let path = "\(projectDir)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: path) {
                jsonlPath = path
            } else {
                return ["messages": [] as [Any], "session_file": "\(sessionId).jsonl", "total_seq": 0]
            }
        } else {
            guard let fallback = findLatestJsonlByCwd(surfaceID: surfaceID) else {
                return ["error": "无法定位会话文件", "messages": []]
            }
            jsonlPath = fallback
        }

        // 安全：验证最终路径必须在 ~/.claude/projects/ 下
        let resolvedPath = (jsonlPath as NSString).resolvingSymlinksInPath
        guard resolvedPath.hasPrefix(Self.claudeProjectsBase) else {
            return ["error": "path_outside_allowed_scope", "messages": []]
        }

        let fm = FileManager.default

        guard let data = fm.contents(atPath: jsonlPath),
              let content = String(data: data, encoding: .utf8) else {
            return ["error": "无法读取会话文件", "messages": []]
        }

        let lines = content.components(separatedBy: "\n")
        var messages: [[String: Any]] = []
        var seq = 0

        // 累计 token 使用量（遍历所有 assistant 消息）
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheCreationTokens = 0
        var totalCacheReadTokens = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let msgType = json["type"] as? String ?? ""

            // 跳过内部事件
            let internalTypes: Set<String> = [
                "file-history-snapshot", "change", "queue-operation", "permission-mode",
            ]
            if internalTypes.contains(msgType) { continue }

            // 只处理 user 和 assistant 消息
            guard msgType == "user" || msgType == "assistant" else { continue }

            // 过滤系统注入的 user 消息（skill 展开、任务通知、命令输出等）
            if msgType == "user", Self.isSystemInjectedUserMessage(json) { continue }

            seq += 1
            if seq <= afterSeq { continue }

            // 提取消息内容
            var msgResult: [String: Any] = [
                "seq": seq,
                "type": msgType,
                "uuid": json["uuid"] as? String ?? "",
                "timestamp": json["timestamp"] as? String ?? "",
            ]

            if let message = json["message"] as? [String: Any] {
                // stop_reason：null=生成中, end_turn=完成, tool_use=等待工具
                if let stopReason = message["stop_reason"] as? String {
                    msgResult["stop_reason"] = stopReason
                }

                if let content = message["content"] {
                    if let textContent = content as? String {
                        msgResult["content"] = [["type": "text", "text": textContent]]
                    } else if let blocks = content as? [[String: Any]] {
                        var cleanBlocks: [[String: Any]] = []
                        for block in blocks {
                            let blockType = block["type"] as? String ?? ""
                            switch blockType {
                            case "text":
                                cleanBlocks.append([
                                    "type": "text",
                                    "text": block["text"] as? String ?? "",
                                ])
                            case "thinking":
                                continue
                            case "tool_use":
                                cleanBlocks.append([
                                    "type": "tool_use",
                                    "name": block["name"] as? String ?? "",
                                    "id": block["id"] as? String ?? "",
                                    "input": block["input"] ?? [:],
                                ])
                            case "tool_result":
                                let resultContent = block["content"]
                                let resultText: String
                                if let str = resultContent as? String {
                                    resultText = str
                                } else if let arr = resultContent as? [[String: Any]] {
                                    resultText = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                                } else {
                                    resultText = ""
                                }
                                cleanBlocks.append([
                                    "type": "tool_result",
                                    "tool_use_id": block["tool_use_id"] as? String ?? "",
                                    "content": String(resultText.prefix(500)),
                                    "is_error": block["is_error"] as? Bool ?? false,
                                ])
                            default:
                                continue
                            }
                        }
                        msgResult["content"] = cleanBlocks
                    }
                }

                if let model = message["model"] as? String {
                    msgResult["model"] = model
                }

                // 累计 token 使用量
                if msgType == "assistant", let usage = message["usage"] as? [String: Any] {
                    totalInputTokens += usage["input_tokens"] as? Int ?? 0
                    totalOutputTokens += usage["output_tokens"] as? Int ?? 0
                    totalCacheCreationTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
                    totalCacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0
                }
            }

            messages.append(msgResult)
        }

        // 推断整体状态：基于最后一条消息
        var status = "idle"
        if let lastMsg = messages.last {
            let lastType = lastMsg["type"] as? String ?? ""
            let lastStop = lastMsg["stop_reason"] as? String
            if lastType == "assistant" && lastStop == nil {
                status = "thinking"
            } else if lastType == "assistant" && lastStop == "tool_use" {
                status = "tool_running"
            } else if lastType == "user" {
                let blocks = lastMsg["content"] as? [[String: Any]] ?? []
                if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                    status = "thinking" // 工具结果返回后 Claude 会继续思考
                }
            }
        }

        #if DEBUG
        dlog("[relay] claude.messages: surfaceID=\(surfaceID.prefix(8)) jsonl=\(jsonlPath.components(separatedBy: "/").last ?? "?") total=\(messages.count) afterSeq=\(afterSeq) status=\(status)")
        #endif

        let totalTokens = totalInputTokens + totalOutputTokens + totalCacheCreationTokens + totalCacheReadTokens
        let usage: [String: Any] = [
            "input_tokens": totalInputTokens,
            "output_tokens": totalOutputTokens,
            "cache_creation_tokens": totalCacheCreationTokens,
            "cache_read_tokens": totalCacheReadTokens,
            "total_tokens": totalTokens,
        ]

        return [
            "messages": messages,
            "session_file": jsonlPath.components(separatedBy: "/").last ?? "",
            "total_seq": seq,
            "status": status,
            "usage": usage,
        ]
    }

    /// 获取 surface 的工作目录
    private func getSurfaceCwd(surfaceID: String) -> String? {
        // 通过 surface.list 查询所有 workspace，找到包含该 surface 的 cwd
        guard let wsResp = sendJsonRPC(method: "workspace.list", params: nil),
              let wsResult = wsResp["result"] as? [String: Any],
              let workspaces = wsResult["workspaces"] as? [[String: Any]] else {
            return nil
        }

        for ws in workspaces {
            guard let wsID = ws["id"] as? String else { continue }
            if let surfResp = sendJsonRPC(method: "surface.list", params: ["workspace_id": wsID]),
               let surfResult = surfResp["result"] as? [String: Any],
               let surfaces = surfResult["surfaces"] as? [[String: Any]] {
                if let surf = surfaces.first(where: { ($0["id"] as? String) == surfaceID }) {
                    // 优先用 surface 的 cwd，其次用 workspace 的 current_directory
                    if let cwd = surf["cwd"] as? String, !cwd.isEmpty {
                        return cwd
                    }
                    if let wsCwd = ws["current_directory"] as? String, !wsCwd.isEmpty {
                        return wsCwd
                    }
                }
            }
        }
        return nil
    }

    /// 将工作目录转换为 Claude 项目路径
    /// /Users/jackie/code/cmux → ~/.claude/projects/-Users-jackie-code-cmux/
    private func claudeProjectPath(forCwd cwd: String) -> String {
        let expandedCwd: String
        if cwd.hasPrefix("~/") {
            expandedCwd = FileManager.default.homeDirectoryForCurrentUser.path + String(cwd.dropFirst(1))
        } else {
            expandedCwd = cwd
        }
        let projectHash = expandedCwd.replacingOccurrences(of: "/", with: "-")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/projects/\(projectHash)"
    }

    /// 从 session store 查找 surface 对应的 Claude session ID
    private func lookupSessionId(forSurface surfaceID: String) -> String? {
        let storePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmuxterm/claude-hook-sessions.json").path
        guard let data = FileManager.default.contents(atPath: storePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [String: [String: Any]] else {
            return nil
        }
        // 遍历 sessions，找到 surfaceId 匹配的记录
        for (sessionId, record) in sessions {
            if let sid = record["surfaceId"] as? String, sid == surfaceID {
                return sessionId
            }
        }
        return nil
    }

    /// 通过 CWD 定位最新的 JSONL 文件（回退方案）
    private func findLatestJsonlByCwd(surfaceID: String) -> String? {
        guard let cwd = getSurfaceCwd(surfaceID: surfaceID) else { return nil }
        let projectDir = claudeProjectPath(forCwd: cwd)
        guard FileManager.default.fileExists(atPath: projectDir) else { return nil }
        return findLatestJsonl(in: projectDir)
    }

    /// 找到目录中当前活跃的 .jsonl 会话文件
    /// 优先选最近 5 分钟内修改过的文件中，包含 user 消息的那个
    private func findLatestJsonl(in directory: String) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        let now = Date()
        let jsonlFiles = contents
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { filename -> (path: String, date: Date)? in
                let path = "\(directory)/\(filename)"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let modDate = attrs[.modificationDate] as? Date else { return nil }
                return (path, modDate)
            }
            .sorted { $0.date > $1.date }

        // 优先选最近 5 分钟内修改的、包含 user/assistant 消息的文件
        let recentThreshold = now.addingTimeInterval(-300)
        for file in jsonlFiles where file.date > recentThreshold {
            if let data = fm.contents(atPath: file.path),
               let content = String(data: data, encoding: .utf8) {
                // 检查是否有对话消息（不只是 permission-mode）
                if content.contains("\"type\":\"user\"") || content.contains("\"type\":\"assistant\"") {
                    return file.path
                }
            }
        }

        // 都没有对话的话，返回最新的（可能是刚启动的空会话）
        return jsonlFiles.first?.path
    }

    // MARK: - JSONL 文件监听（服务端推送）

    /// 开始监听指定 surface 的 Claude JSONL 文件变化
    /// 当文件有新内容写入时，自动读取增量并推送给手机
    func startWatchingClaude(surfaceID: String) {
        watcherQueue.async { [weak self] in
            guard let self else { return }

            // 如果已在监听，先停止
            self.stopWatchingClaudeSync(surfaceID: surfaceID)

            // 定位 JSONL 文件
            let jsonlPath: String
            if let sessionId = self.lookupSessionId(forSurface: surfaceID),
               Self.isValidID(sessionId) {
                let cwd = self.getSurfaceCwd(surfaceID: surfaceID) ?? ""
                let projectDir = self.claudeProjectPath(forCwd: cwd)
                let path = "\(projectDir)/\(sessionId).jsonl"
                guard FileManager.default.fileExists(atPath: path) else { return }
                jsonlPath = path
            } else if let fallback = self.findLatestJsonlByCwd(surfaceID: surfaceID) {
                jsonlPath = fallback
            } else {
                return
            }

            // 打开文件描述符
            let fd = Darwin.open(jsonlPath, O_RDONLY | O_EVTONLY)
            guard fd >= 0 else { return }

            // 记录当前文件大小
            let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath)
            let currentSize = (attrs?[.size] as? UInt64) ?? 0

            // 创建 DispatchSource 监听文件写入
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend],
                queue: self.watcherQueue
            )

            source.setEventHandler { [weak self] in
                self?.handleJsonlChange(surfaceID: surfaceID, path: jsonlPath)
            }

            source.setCancelHandler {
                Darwin.close(fd)
            }

            self.jsonlWatchers[jsonlPath] = (fd, source, currentSize)
            self.watchedSurfaces[surfaceID] = jsonlPath

            source.resume()

            #if DEBUG
            dlog("[relay] 开始监听 JSONL: \(jsonlPath.components(separatedBy: "/").last ?? "?") for surface \(surfaceID.prefix(8))")
            #endif
        }
    }

    /// 停止监听指定 surface
    func stopWatchingClaude(surfaceID: String) {
        watcherQueue.async { [weak self] in
            self?.stopWatchingClaudeSync(surfaceID: surfaceID)
        }
    }

    private func stopWatchingClaudeSync(surfaceID: String) {
        guard let path = watchedSurfaces.removeValue(forKey: surfaceID),
              let watcher = jsonlWatchers.removeValue(forKey: path) else { return }
        watcher.source.cancel()
        #if DEBUG
        dlog("[relay] 停止监听 JSONL: surface \(surfaceID.prefix(8))")
        #endif
    }

    /// 停止所有监听
    func stopAllWatchers() {
        watcherQueue.async { [weak self] in
            guard let self else { return }
            for (_, watcher) in self.jsonlWatchers {
                watcher.source.cancel()
            }
            self.jsonlWatchers.removeAll()
            self.watchedSurfaces.removeAll()
        }
    }

    /// 文件变化时读取增量内容并推送
    private func handleJsonlChange(surfaceID: String, path: String) {
        guard var watcher = jsonlWatchers[path] else { return }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let newSize = (attrs?[.size] as? UInt64) ?? 0

        // 文件没有变大，跳过
        guard newSize > watcher.lastSize else { return }

        // 读取新增内容
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { fh.closeFile() }

        fh.seek(toFileOffset: watcher.lastSize)
        let newData = fh.readDataToEndOfFile()
        watcher.lastSize = newSize
        jsonlWatchers[path] = watcher

        guard let newContent = String(data: newData, encoding: .utf8) else { return }

        // 解析新增的 JSON 行
        var newMessages: [[String: Any]] = []
        // 增量 token 使用量（本次新增消息的 usage）
        var deltaInputTokens = 0
        var deltaOutputTokens = 0
        var deltaCacheCreationTokens = 0
        var deltaCacheReadTokens = 0
        for line in newContent.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let msgType = json["type"] as? String ?? ""
            guard msgType == "user" || msgType == "assistant" else { continue }

            // 过滤系统注入的 user 消息
            if msgType == "user", Self.isSystemInjectedUserMessage(json) { continue }

            // 复用 readClaudeMessages 的消息解析逻辑
            var msgResult: [String: Any] = [
                "type": msgType,
                "uuid": json["uuid"] as? String ?? "",
                "timestamp": json["timestamp"] as? String ?? "",
            ]

            if let message = json["message"] as? [String: Any] {
                if let stopReason = message["stop_reason"] as? String {
                    msgResult["stop_reason"] = stopReason
                }
                if let content = message["content"] {
                    if let textContent = content as? String {
                        msgResult["content"] = [["type": "text", "text": textContent]]
                    } else if let blocks = content as? [[String: Any]] {
                        var cleanBlocks: [[String: Any]] = []
                        for block in blocks {
                            let blockType = block["type"] as? String ?? ""
                            switch blockType {
                            case "text":
                                cleanBlocks.append(["type": "text", "text": block["text"] as? String ?? ""])
                            case "tool_use":
                                cleanBlocks.append([
                                    "type": "tool_use", "name": block["name"] as? String ?? "",
                                    "id": block["id"] as? String ?? "", "input": block["input"] ?? [:],
                                ])
                            case "tool_result":
                                let resultContent = block["content"]
                                let resultText: String
                                if let str = resultContent as? String { resultText = str }
                                else if let arr = resultContent as? [[String: Any]] {
                                    resultText = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                                } else { resultText = "" }
                                cleanBlocks.append([
                                    "type": "tool_result",
                                    "tool_use_id": block["tool_use_id"] as? String ?? "",
                                    "content": String(resultText.prefix(500)),
                                    "is_error": block["is_error"] as? Bool ?? false,
                                ])
                            default: continue
                            }
                        }
                        msgResult["content"] = cleanBlocks
                    }
                }
                if let model = message["model"] as? String {
                    msgResult["model"] = model
                }

                // 累计增量 token 使用量
                if msgType == "assistant", let usage = message["usage"] as? [String: Any] {
                    deltaInputTokens += usage["input_tokens"] as? Int ?? 0
                    deltaOutputTokens += usage["output_tokens"] as? Int ?? 0
                    deltaCacheCreationTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
                    deltaCacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0
                }
            }

            newMessages.append(msgResult)
        }

        guard !newMessages.isEmpty else { return }

        // 推断状态
        var status = "idle"
        if let lastMsg = newMessages.last {
            let lastType = lastMsg["type"] as? String ?? ""
            let lastStop = lastMsg["stop_reason"] as? String
            if lastType == "assistant" && lastStop == nil { status = "thinking" }
            else if lastType == "assistant" && lastStop == "tool_use" { status = "tool_running" }
            else if lastType == "user" {
                let blocks = lastMsg["content"] as? [[String: Any]] ?? []
                if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { status = "thinking" }
            }
        }

        // 推送增量消息到手机（含增量 token 使用量）
        let deltaTotal = deltaInputTokens + deltaOutputTokens + deltaCacheCreationTokens + deltaCacheReadTokens
        let deltaUsage: [String: Any] = [
            "input_tokens": deltaInputTokens,
            "output_tokens": deltaOutputTokens,
            "cache_creation_tokens": deltaCacheCreationTokens,
            "cache_read_tokens": deltaCacheReadTokens,
            "total_tokens": deltaTotal,
        ]
        pushEvent("claude.messages.update", payload: [
            "surface_id": surfaceID,
            "messages": newMessages,
            "status": status,
            "usage": deltaUsage,
        ])

        #if DEBUG
        dlog("[relay] JSONL 推送: surface=\(surfaceID.prefix(8)) new=\(newMessages.count) status=\(status)")
        #endif
    }
}
