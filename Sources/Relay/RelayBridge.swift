import Bonsplit
import Foundation

// MARK: - RelayBridge

/// 将 WebSocket 消息桥接到本地 cmux Unix socket（JSON-RPC）
/// 负责：解析 Relay Envelope → 转发到本地 socket → 包装响应回传
final class RelayBridge {

    struct ClaudeHistorySnapshot {
        let fileSize: UInt64
        let modifiedAt: Date?
        let messages: [[String: Any]]
        let totalSeq: Int
        let status: String
        let usage: [String: Any]
    }

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
    /// Claude JSONL 解析缓存，避免同一文件在未变化时被重复整份扫描
    private var claudeHistoryCache: [String: ClaudeHistorySnapshot] = [:]
    private let claudeHistoryCacheLock = NSLock()
    /// 正在解析中的路径集合，避免并发请求重复 I/O+parse（TOCTOU 修复）
    /// 值为 NSCondition，用于唤醒等待同一路径解析完成的其他线程
    private var claudeHistoryInflight: [String: NSCondition] = [:]

    // MARK: - Claude 阶段状态

    /// 上次上报的 Claude 阶段（避免重复推送）
    /// internal：RelayAgentApproval 需要直接更新此状态
    var lastReportedPhase: String = "idle"

    // MARK: - 模型切换状态

    /// 模型切换互斥标志，防止并发切换
    private var isModelSwitching = false
    /// 保护 isModelSwitching 的队列
    private let modelSwitchQueue = DispatchQueue(label: "com.cmux.relay.modelSwitch")

    // MARK: - RPC 响应去重缓存

    /// RPC 响应去重缓存（request_id → 缓存结果，60 秒 TTL）
    private var recentResponses: [String: (response: [String: Any], timestamp: Date)] = [:]
    private let responseCacheLock = NSLock()
    /// 请求 ID（Int）→ 手机端 request_id（UUID），供 sendRPCResponse 查找缓存键
    private var pendingRequestUUIDs: [Int: String] = [:]

    // MARK: - 持久化 Socket 连接

    /// 复用的 Unix socket 文件描述符，避免每次 RPC 都重新建连
    private var persistentFd: Int32?
    /// 保护 persistentFd 的串行队列
    private let socketQueue = DispatchQueue(label: "com.cmux.relay.socket")

    // MARK: - 能力快照：Slash 命令扫描

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
        // 手机端生成的 UUID，用于 RPC 去重
        let requestUUID = payload["request_id"] as? String

        #if DEBUG
        dlog("[relay] RPC method='\(method)' id=\(requestID) payload.keys=\(payload.keys.sorted())")
        #endif

        switch msgType {
        case "rpc_request":
            // RPC 去重检查：同一 request_id 命中时直接返回缓存响应
            if let uuid = requestUUID, let cached = getCachedResponse(requestId: uuid) {
                #if DEBUG
                dlog("[relay] 去重命中: request_id=\(uuid.prefix(8))")
                #endif
                sendRPCResponse(requestID: requestID, result: cached)
                return
            }
            // 注册 requestID → requestUUID 映射，供 sendRPCResponse 缓存响应
            if let uuid = requestUUID {
                responseCacheLock.lock()
                pendingRequestUUIDs[requestID] = uuid
                responseCacheLock.unlock()
            }
            handleRPCRequest(method: method, params: params, requestID: requestID, requestUUID: requestUUID)
        default:
            // 其他消息类型（resume 等由 relay 服务器处理）
            break
        }
    }

    // MARK: - RPC 请求路由

    /// 根据 method 路由到不同处理器
    private func handleRPCRequest(method: String, params: [String: Any]?, requestID: Int, requestUUID: String? = nil) {
        switch method {
        // Agent 审批
        case "agent.approve", "agent.reject":
            let approved = method == "agent.approve"
            let approvalRequestID = params?["request_id"] as? String ?? ""
            agentApproval?.handleApprovalResponse(requestID: approvalRequestID, approved: approved)
            sendRPCResponse(requestID: requestID, result: ["ok": true])

        // 文件操作
        case "file.list", "file.read", "file.mkdir":
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
                let result: [String: Any]
                if let params, !params.isEmpty {
                    result = self.forwardingResult(method: method, params: params)
                } else {
                    result = self.collectAllSurfacesResult()
                }
                #if DEBUG
                dlog("[relay] surface.list 完成, keys=\(result.keys.sorted())")
                #endif
                self.sendRPCResponse(requestID: requestID, result: result)
            }

        // 状态变更命令：执行后推送更新的 surface 列表
        case "workspace.create", "workspace.close",
             "surface.close", "surface.create", "surface.split",
             "pane.create", "pane.close", "pane.break", "pane.join":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                // Surface/pane 关闭时清理对应的 JSONL watcher
                if method == "surface.close" || method == "pane.close" || method == "workspace.close" {
                    if let surfaceID = params?["surface_id"] as? String, Self.isValidID(surfaceID) {
                        self.stopWatchingClaude(surfaceID: surfaceID)
                    }
                }
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
                let beforeSeq = params?["before_seq"] as? Int
                let limit = params?["limit"] as? Int
                let result = self.readClaudeMessages(
                    surfaceID: surfaceID,
                    afterSeq: afterSeq,
                    beforeSeq: beforeSeq,
                    limit: limit
                )
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

    // MARK: - RPC 去重缓存辅助方法

    /// 查找缓存的 RPC 响应
    private func getCachedResponse(requestId: String) -> [String: Any]? {
        responseCacheLock.lock()
        defer { responseCacheLock.unlock() }
        guard let entry = recentResponses[requestId] else { return nil }
        // 60 秒 TTL
        if Date().timeIntervalSince(entry.timestamp) > 60 {
            recentResponses.removeValue(forKey: requestId)
            return nil
        }
        return entry.response
    }

    /// 缓存 RPC 响应
    private func cacheResponse(requestId: String, response: [String: Any]) {
        responseCacheLock.lock()
        recentResponses[requestId] = (response, Date())
        // 清理过期条目（超过 100 条时才触发，避免每次都遍历）
        if recentResponses.count > 100 {
            let cutoff = Date().addingTimeInterval(-60)
            recentResponses = recentResponses.filter { $0.value.timestamp > cutoff }
        }
        responseCacheLock.unlock()
    }

    // MARK: - 转发到本地 Socket

    /// 统一的自增 RPC ID 计数器（线程安全），所有 RPC 请求共用
    private static var rpcIDCounter: Int = 0
    private static let rpcIDLock = NSLock()

    /// 生成线程安全的自增 RPC ID
    static func nextRpcID() -> Int {
        rpcIDLock.lock()
        rpcIDCounter += 1
        let id = rpcIDCounter
        rpcIDLock.unlock()
        return id
    }

    /// 转发到本地 socket（不等待响应，供内部模块调用）
    func forwardToSocketDirect(method: String, params: [String: Any]) {
        let currentID = Self.nextRpcID()
        let rpcRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": currentID,
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
            // - 出现 box-drawing 边框（╭╮╰╯─）表示 TUI 已渲染
            // - 出现 Context/Usage 状态栏
            let hasBoxDrawing = lastContent.contains("╭") || lastContent.contains("╰") || lastContent.contains("───")
            let hasStatusBar = lastContent.contains("Context") && lastContent.contains("%")

            if hasBoxDrawing || hasStatusBar {
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
        // 缓存响应用于去重（若有对应的 request_id UUID）
        responseCacheLock.lock()
        if let uuid = pendingRequestUUIDs.removeValue(forKey: requestID) {
            responseCacheLock.unlock()
            cacheResponse(requestId: uuid, response: result)
        } else {
            responseCacheLock.unlock()
        }
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

    /// 推送 Claude 阶段变化事件到 iPhone（仅在状态变化时推送）
    /// internal：RelayAgentApproval 需要直接调用此方法
    func pushPhaseEvent(phase: String, surfaceID: String, toolName: String? = nil, projectName: String? = nil, lastUserMessage: String? = nil, lastAssistantSummary: String? = nil) {
        var payload: [String: Any] = [
            "event": "phase.update",
            "surface_id": surfaceID,
            "phase": phase,
        ]
        if let toolName { payload["tool_name"] = toolName }
        if let projectName { payload["project_name"] = projectName }
        if let lastUserMessage { payload["last_user_message"] = String(lastUserMessage.prefix(120)) }
        if let lastAssistantSummary { payload["last_assistant_summary"] = String(lastAssistantSummary.prefix(200)) }

        // push_hint 让 relay server 知道该触发 APNs 推送
        var pushHint: [String: String] = ["event": "phase", "phase": phase]
        if phase == "ended" {
            pushHint["summary"] = lastAssistantSummary.map { String($0.prefix(100)) } ?? "Claude 已完成"
        } else if phase == "waiting_approval" {
            pushHint["summary"] = "需要审批: \(toolName ?? "工具调用")"
        }

        pushEvent("phase.update", payload: payload, pushHint: pushHint)
    }

    /// 扫描 Claude Code 命令/技能目录，构建完整的可用命令列表
    private func scanCapabilities() -> [[String: Any]] {
        var commands: [[String: Any]] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // 1. 内置命令（始终存在）
        commands.append(contentsOf: builtinCommands())

        // 2. 全局用户命令: ~/.claude/commands/*.md
        let globalCmdsDir = "\(home)/.claude/commands"
        commands.append(contentsOf: scanCommandDirectory(globalCmdsDir, category: "user"))

        // 3. 全局用户技能: ~/.claude/skills/*/SKILL.md
        let globalSkillsDir = "\(home)/.claude/skills"
        commands.append(contentsOf: scanSkillsDirectory(globalSkillsDir, category: "skill"))

        // 4. 插件命令和技能: ~/.claude/plugins/cache/*/*/
        let pluginCacheDir = "\(home)/.claude/plugins/cache"
        if let orgs = try? fm.contentsOfDirectory(atPath: pluginCacheDir) {
            for org in orgs {
                let orgPath = "\(pluginCacheDir)/\(org)"
                guard let plugins = try? fm.contentsOfDirectory(atPath: orgPath) else { continue }
                for plugin in plugins {
                    let pluginPath = "\(orgPath)/\(plugin)"
                    // 找最新版本目录
                    guard let versions = try? fm.contentsOfDirectory(atPath: pluginPath) else { continue }
                    guard let latestVersion = versions.sorted().last else { continue }
                    let versionPath = "\(pluginPath)/\(latestVersion)"

                    let prefix = "\(org):\(plugin)"
                    // 插件命令
                    let cmdsPath = "\(versionPath)/commands"
                    commands.append(contentsOf: scanCommandDirectory(cmdsPath, category: "plugin", prefix: prefix))
                    // 插件技能
                    let skillsPath = "\(versionPath)/skills"
                    commands.append(contentsOf: scanSkillsDirectory(skillsPath, category: "plugin", prefix: prefix))
                }
            }
        }

        // 5. 项目命令（遍历已知 surface 的 CWD）
        for (surfaceID, _) in watchedSurfaces {
            if let cwd = getSurfaceCwd(surfaceID: surfaceID) {
                let projectCmdsDir = "\(cwd)/.claude/commands"
                commands.append(contentsOf: scanCommandDirectory(projectCmdsDir, category: "project"))
            }
        }

        return commands
    }

    /// 扫描命令目录（.md 文件），支持命名空间子目录
    private func scanCommandDirectory(_ path: String, category: String, prefix: String? = nil) -> [[String: Any]] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var commands: [[String: Any]] = []

        for entry in entries {
            let fullPath = "\(path)/\(entry)"
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)

            if isDir.boolValue {
                // 命名空间子目录: commands/ns/*.md → /ns:command
                let nsCommands = scanCommandDirectory(fullPath, category: category, prefix: entry)
                commands.append(contentsOf: nsCommands)
            } else if entry.hasSuffix(".md") {
                let name = String(entry.dropLast(3)) // 去掉 .md
                let cmdName: String
                if let prefix {
                    cmdName = "/\(prefix):\(name)"
                } else {
                    cmdName = "/\(name)"
                }
                let description = extractFrontmatterDescription(fullPath)
                commands.append([
                    "command": cmdName,
                    "description": description ?? name,
                    "category": category,
                ])
            }
        }
        return commands
    }

    /// 扫描技能目录（子目录下的 SKILL.md 或 skill.md）
    private func scanSkillsDirectory(_ path: String, category: String, prefix: String? = nil) -> [[String: Any]] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        var commands: [[String: Any]] = []

        for entry in entries {
            let skillMdPath = "\(path)/\(entry)/SKILL.md"
            let skillMdPathLower = "\(path)/\(entry)/skill.md"
            let actualPath = fm.fileExists(atPath: skillMdPath) ? skillMdPath :
                             fm.fileExists(atPath: skillMdPathLower) ? skillMdPathLower : nil
            guard let mdPath = actualPath else { continue }

            let name: String
            if let prefix {
                name = "\(prefix):\(entry)"
            } else {
                name = entry
            }
            let description = extractFrontmatterDescription(mdPath)
            commands.append([
                "command": "/\(name)",
                "description": description ?? entry,
                "category": category,
            ])
        }
        return commands
    }

    /// 从 Markdown 文件头部提取 YAML frontmatter 的 description 字段
    private func extractFrontmatterDescription(_ filePath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        for i in 1..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == "---" { break }
            if line.hasPrefix("description:") {
                let value = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                // 去掉引号
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    return String(value.dropFirst().dropLast())
                }
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// 内置 Claude Code 系统命令（固定列表，始终推送）
    private func builtinCommands() -> [[String: Any]] {
        return [
            ["command": "/compact", "description": "压缩上下文", "category": "common"],
            ["command": "/status", "description": "查看状态", "category": "common"],
            ["command": "/clear", "description": "清除对话", "category": "common"],
            ["command": "/help", "description": "帮助", "category": "common"],
            ["command": "/cost", "description": "费用统计", "category": "common"],
            ["command": "/init", "description": "初始化项目", "category": "project"],
            ["command": "/review", "description": "代码审查", "category": "project"],
            ["command": "/bug", "description": "报告/调试 bug", "category": "project"],
            ["command": "/memory", "description": "记忆管理", "category": "config"],
            ["command": "/mcp", "description": "MCP 服务", "category": "tools"],
            ["command": "/model", "description": "切换模型", "category": "tools", "interactive": true, "options": [
                ["key": "default", "label": "Default (推荐)"],
                ["key": "sonnet", "label": "Sonnet 4.6"],
                ["key": "haiku", "label": "Haiku 4.5"],
                ["key": "opus", "label": "Opus 4.6"],
            ]],
            ["command": "/doctor", "description": "诊断", "category": "tools"],
            ["command": "/listen", "description": "监听模式", "category": "tools"],
            // 手机上不可用的命令
            ["command": "/config", "description": "配置", "category": "config", "disabled": true, "disabledReason": "需要 TUI 交互"],
            ["command": "/permissions", "description": "权限管理", "category": "config", "disabled": true, "disabledReason": "需要 TUI 交互"],
            ["command": "/vim", "description": "Vim 模式", "category": "tools", "disabled": true, "disabledReason": "需要 TUI 交互"],
            ["command": "/allowed-tools", "description": "管理允许的工具", "category": "config", "disabled": true, "disabledReason": "需要 TUI 交互"],
            ["command": "/install-github-app", "description": "安装 GitHub App", "category": "tools"],
        ]
    }

    /// 推送能力快照到 iPhone（动态扫描后的 slash 命令列表）
    func pushCapabilities() {
        let commands = scanCapabilities()
        pushEvent("capabilities.snapshot", payload: [
            "slash_commands": commands,
            "allowed_directories": RelaySettings.allowedDirectories,
            "version": 2,
        ])
        #if DEBUG
        dlog("[relay] 推送 \(commands.count) 个命令/技能")
        #endif
    }

    /// 推送所有 workspace 的 surface 列表到手机端
    func pushSurfaceList() {
        #if DEBUG
        dlog("[relay] pushSurfaceList 被调用")
        #endif
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.collectAllSurfacesResult()
            #if DEBUG
            dlog("[relay] pushSurfaceList: keys=\(result.keys.sorted())")
            #endif
            self.pushEvent("surface.list_update", payload: result)
        }
    }

    /// 收集所有 workspace 的 surfaces
    /// 注意：使用 workspace_id 参数直接查询，不切换当前 workspace，避免 UI 卡顿
    private func collectAllSurfacesResult() -> [String: Any] {
        guard let wsResp = sendJsonRPC(method: "workspace.list", params: nil) else {
            return ["error": "workspace_list_unavailable", "message": "workspace.list returned no response"]
        }
        if let errorResult = normalizedErrorResult(from: wsResp) {
            return errorResult
        }
        guard let wsResult = wsResp["result"] as? [String: Any],
              let workspaces = wsResult["workspaces"] as? [[String: Any]] else {
            return ["error": "workspace_list_invalid", "message": "workspace.list returned invalid payload"]
        }

        var allSurfaces: [[String: Any]] = []

        for ws in workspaces {
            guard let wsID = ws["id"] as? String else { continue }
            let wsTitle = ws["title"] as? String ?? ""
            let wsCwd = ws["current_directory"] as? String ?? ""
            let wsName = wsCwd.isEmpty ? wsTitle : wsCwd

            // 使用 workspace_id 参数直接查询，不需要 workspace.select
            if let surfResp = sendJsonRPC(method: "surface.list", params: ["workspace_id": wsID]),
               normalizedErrorResult(from: surfResp) == nil,
               let surfResult = surfResp["result"] as? [String: Any],
               let surfaces = surfResult["surfaces"] as? [[String: Any]] {
                for var surf in surfaces {
                    surf["workspace_id"] = wsID
                    surf["workspace_name"] = wsName
                    allSurfaces.append(surf)
                }
            }
        }

        return ["surfaces": allSurfaces]
    }

    /// 发送 JSON-RPC 请求并返回解析后的响应（自动加锁）
    private func sendJsonRPC(method: String, params: [String: Any]?) -> [String: Any]? {
        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": Self.nextRpcID(),
            "params": params ?? [:],
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8),
              let response = sendToUnixSocket(jsonString),
              let responseData = response.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    private func forwardingResult(method: String, params: [String: Any]) -> [String: Any] {
        guard let response = sendJsonRPC(method: method, params: params) else {
            return ["error": "socket_unavailable", "message": "\(method) returned no response"]
        }
        if let errorResult = normalizedErrorResult(from: response) {
            return errorResult
        }
        return (response["result"] as? [String: Any]) ?? response
    }

    private func normalizedErrorResult(from response: [String: Any]) -> [String: Any]? {
        if let error = response["error"] as? [String: Any] {
            return [
                "error": error["code"] as? String ?? "rpc_error",
                "message": error["message"] as? String ?? "RPC failed",
                "data": error["data"] as Any
            ]
        }
        if let error = response["error"] as? String {
            return [
                "error": error,
                "message": response["message"] as? String ?? error
            ]
        }
        return nil
    }

    /// 不持锁版本，供已在 socketQueue 内的代码调用
    private func _sendJsonRPCUnsafe(method: String, params: [String: Any]?) -> [String: Any]? {
        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "id": Self.nextRpcID(),
            "params": params ?? [:],
        ]

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
                "id": Self.nextRpcID(),
                "params": [:],
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

        case "file.mkdir":
            guard let path = params?["path"] as? String else {
                return ["error": "缺少 path 参数"]
            }
            let expandedPath = (path as NSString).expandingTildeInPath
            do {
                // 验证父目录在沙箱内
                let parentDir = (expandedPath as NSString).deletingLastPathComponent
                _ = try fileHandler?.sandbox.validate(path: parentDir)
                try FileManager.default.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)
                return ["ok": true]
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

    private func readClaudeMessages(surfaceID: String, afterSeq: Int, beforeSeq: Int? = nil, limit: Int? = nil) -> [String: Any] {
        let requestStartedAt = CFAbsoluteTimeGetCurrent()
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
            // 不使用 CWD 回退，避免匹配到同目录其他 Claude 实例的会话
            return ["error": "session_not_found", "messages": [] as [Any], "total_seq": 0]
        }

        // 安全：验证最终路径必须在 ~/.claude/projects/ 下
        let resolvedPath = (jsonlPath as NSString).resolvingSymlinksInPath
        guard resolvedPath.hasPrefix(Self.claudeProjectsBase) else {
            return ["error": "path_outside_allowed_scope", "messages": []]
        }

        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: jsonlPath)
        let fileSize = (attrs?[.size] as? UInt64) ?? 0
        let modifiedAt = attrs?[.modificationDate] as? Date

        guard let snapshot = loadClaudeHistorySnapshot(
            path: jsonlPath,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        ) else {
            return ["error": "无法读取会话文件", "messages": []]
        }
        let paginateStartedAt = CFAbsoluteTimeGetCurrent()
        let page = paginateClaudeHistory(
            snapshot: snapshot,
            afterSeq: afterSeq,
            beforeSeq: beforeSeq,
            limit: limit
        )

        #if DEBUG
        let paginateMs = Int((CFAbsoluteTimeGetCurrent() - paginateStartedAt) * 1000)
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - requestStartedAt) * 1000)
        dlog("[relay] claude.messages: surfaceID=\(surfaceID.prefix(8)) jsonl=\(jsonlPath.components(separatedBy: "/").last ?? "?") returned=\(page.messages.count) total=\(snapshot.messages.count) afterSeq=\(afterSeq) beforeSeq=\(beforeSeq ?? 0) limit=\(limit ?? 0) hasMore=\(page.hasMore) status=\(snapshot.status) paginateMs=\(paginateMs) totalMs=\(totalMs)")
        #endif

        return [
            "messages": page.messages,
            "session_file": jsonlPath.components(separatedBy: "/").last ?? "",
            "total_seq": snapshot.totalSeq,
            "status": snapshot.status,
            "usage": snapshot.usage,
            "has_more": page.hasMore,
            "next_before_seq": page.nextBeforeSeq,
        ]
    }

    func loadClaudeHistorySnapshot(
        path: String,
        fileSize: UInt64,
        modifiedAt: Date?
    ) -> ClaudeHistorySnapshot? {
        let startedAt = CFAbsoluteTimeGetCurrent()

        // 检查缓存 + inflight，使用同一把锁避免 TOCTOU
        claudeHistoryCacheLock.lock()
        if let cached = claudeHistoryCache[path],
           cached.fileSize == fileSize,
           cached.modifiedAt == modifiedAt {
            claudeHistoryCacheLock.unlock()
            #if DEBUG
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            dlog("[relay] claude.history cache hit path=\((path as NSString).lastPathComponent) totalSeq=\(cached.totalSeq) elapsedMs=\(elapsedMs)")
            #endif
            return cached
        }

        // 如果已有其他线程在解析同一路径，等待其完成后读缓存
        if let condition = claudeHistoryInflight[path] {
            claudeHistoryCacheLock.unlock()
            // NSCondition 使用协议：持有 condition 锁 → 检查谓词 → wait → 再检查
            condition.lock()
            while true {
                claudeHistoryCacheLock.lock()
                let stillInflight = claudeHistoryInflight[path] === condition
                claudeHistoryCacheLock.unlock()
                if !stillInflight { break }
                condition.wait()
            }
            condition.unlock()

            // 解析完成后读缓存
            claudeHistoryCacheLock.lock()
            let cached = claudeHistoryCache[path]
            claudeHistoryCacheLock.unlock()

            #if DEBUG
            if let cached {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                dlog("[relay] claude.history inflight wait hit path=\((path as NSString).lastPathComponent) totalSeq=\(cached.totalSeq) elapsedMs=\(elapsedMs)")
            }
            #endif
            // 校验 fileSize/modifiedAt 是否匹配本次请求；若不匹配则重新解析
            if let cached,
               cached.fileSize == fileSize,
               cached.modifiedAt == modifiedAt {
                return cached
            }
            // 不匹配：文件被再次修改，递归重新检查/解析
            return loadClaudeHistorySnapshot(path: path, fileSize: fileSize, modifiedAt: modifiedAt)
        }

        // 占位 inflight，unlock 后做 I/O
        let condition = NSCondition()
        claudeHistoryInflight[path] = condition
        claudeHistoryCacheLock.unlock()

        // 确保异常路径也会清理 inflight 并唤醒等待者
        func finishInflight(withSnapshot snapshot: ClaudeHistorySnapshot?) {
            claudeHistoryCacheLock.lock()
            if let snapshot {
                claudeHistoryCache[path] = snapshot
            }
            claudeHistoryInflight.removeValue(forKey: path)
            claudeHistoryCacheLock.unlock()
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        let readStartedAt = CFAbsoluteTimeGetCurrent()
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            finishInflight(withSnapshot: nil)
            return nil
        }
        let readMs = Int((CFAbsoluteTimeGetCurrent() - readStartedAt) * 1000)

        let parseStartedAt = CFAbsoluteTimeGetCurrent()
        let snapshot = parseClaudeHistorySnapshot(
            content: content,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        )
        let parseMs = Int((CFAbsoluteTimeGetCurrent() - parseStartedAt) * 1000)

        finishInflight(withSnapshot: snapshot)

        #if DEBUG
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        dlog("[relay] claude.history cache miss path=\((path as NSString).lastPathComponent) bytes=\(fileSize) totalSeq=\(snapshot.totalSeq) readMs=\(readMs) parseMs=\(parseMs) totalMs=\(totalMs)")
        #endif
        return snapshot
    }

    /// 失效指定路径的 Claude 历史快照缓存。
    /// 会同步清理 inflight 条目并唤醒等待者，避免被其它线程长期阻塞。
    func invalidateClaudeHistorySnapshot(path: String) {
        claudeHistoryCacheLock.lock()
        let condition = invalidateClaudeHistorySnapshot_locked(path: path)
        claudeHistoryCacheLock.unlock()
        // broadcast 必须在释放 cacheLock 之后进行，避免持有多把锁
        if let condition {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }
    }

    /// 假定调用方已持有 `claudeHistoryCacheLock` 的版本。
    /// 返回需要在释放锁后 broadcast 的 inflight condition（若存在）。
    /// 调用方必须负责在释放 `claudeHistoryCacheLock` 之后对返回的 condition 进行 broadcast。
    @discardableResult
    private func invalidateClaudeHistorySnapshot_locked(path: String) -> NSCondition? {
        claudeHistoryCache.removeValue(forKey: path)
        // 同时清理 inflight 占位，返回 condition 给调用方 broadcast
        return claudeHistoryInflight.removeValue(forKey: path)
    }

    func parseClaudeHistorySnapshot(
        content: String,
        fileSize: UInt64,
        modifiedAt: Date?
    ) -> ClaudeHistorySnapshot {
        let lines = content.components(separatedBy: "\n")
        var messages: [[String: Any]] = []
        var seq = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheCreationTokens = 0
        var totalCacheReadTokens = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let msgType = json["type"] as? String ?? ""
            let internalTypes: Set<String> = [
                "file-history-snapshot", "change", "queue-operation", "permission-mode",
            ]
            if internalTypes.contains(msgType) { continue }
            guard msgType == "user" || msgType == "assistant" else { continue }
            if msgType == "user", Self.isSystemInjectedUserMessage(json) { continue }

            seq += 1
            var msgResult: [String: Any] = [
                "seq": seq,
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

                if msgType == "assistant", let usage = message["usage"] as? [String: Any] {
                    totalInputTokens += usage["input_tokens"] as? Int ?? 0
                    totalOutputTokens += usage["output_tokens"] as? Int ?? 0
                    totalCacheCreationTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
                    totalCacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0
                }
            }

            messages.append(msgResult)
        }

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
                    status = "thinking"
                }
            }
        }

        let totalTokens = totalInputTokens + totalOutputTokens + totalCacheCreationTokens + totalCacheReadTokens
        let usage: [String: Any] = [
            "input_tokens": totalInputTokens,
            "output_tokens": totalOutputTokens,
            "cache_creation_tokens": totalCacheCreationTokens,
            "cache_read_tokens": totalCacheReadTokens,
            "total_tokens": totalTokens,
        ]

        return ClaudeHistorySnapshot(
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            messages: messages,
            totalSeq: seq,
            status: status,
            usage: usage
        )
    }

    func paginateClaudeHistory(
        snapshot: ClaudeHistorySnapshot,
        afterSeq: Int,
        beforeSeq: Int?,
        limit: Int?
    ) -> (messages: [[String: Any]], hasMore: Bool, nextBeforeSeq: Int) {
        let messages = snapshot.messages.filter { ($0["seq"] as? Int ?? 0) > afterSeq }

        let selectedMessages: [[String: Any]]
        let hasMore: Bool
        if let beforeSeq, beforeSeq > 0 {
            let candidate = messages.filter { ($0["seq"] as? Int ?? 0) < beforeSeq }
            if let limit, limit > 0, candidate.count > limit {
                selectedMessages = Array(candidate.suffix(limit))
            } else {
                selectedMessages = candidate
            }
            hasMore = (selectedMessages.first?["seq"] as? Int ?? 0) > 1
        } else if let limit, limit > 0, afterSeq <= 0 {
            if messages.count > limit {
                selectedMessages = Array(messages.suffix(limit))
            } else {
                selectedMessages = messages
            }
            hasMore = messages.count > selectedMessages.count
        } else {
            selectedMessages = messages
            hasMore = false
        }

        let nextBeforeSeq = (selectedMessages.first?["seq"] as? Int) ?? 0
        return (selectedMessages, hasMore, nextBeforeSeq)
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

            // 定位 JSONL 文件（严格通过 session store 匹配，不使用 CWD 回退）
            // CWD 回退会在同目录多个 Claude 实例时匹配到错误的会话
            guard let sessionId = self.lookupSessionId(forSurface: surfaceID),
                  Self.isValidID(sessionId) else {
                #if DEBUG
                dlog("[relay] claude.watch: session store 无此 surface 记录 (\(surfaceID.prefix(8)))，等待 SessionStart hook 注册")
                #endif
                return
            }
            let cwd = self.getSurfaceCwd(surfaceID: surfaceID) ?? ""
            let projectDir = self.claudeProjectPath(forCwd: cwd)
            let jsonlPath = "\(projectDir)/\(sessionId).jsonl"
            guard FileManager.default.fileExists(atPath: jsonlPath) else {
                #if DEBUG
                dlog("[relay] claude.watch: JSONL 文件不存在 (session=\(sessionId.prefix(8)), path=\(jsonlPath.components(separatedBy: "/").last ?? "?"))")
                #endif
                return
            }

            // 打开文件描述符
            let fd = Darwin.open(jsonlPath, O_RDONLY | O_EVTONLY)
            guard fd >= 0 else { return }

            // 记录当前文件大小
            let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath)
            let currentSize = (attrs?[.size] as? UInt64) ?? 0

            // 创建 DispatchSource 监听文件写入、删除、重命名
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename],
                queue: self.watcherQueue
            )

            source.setEventHandler { [weak self] in
                guard let self else { return }
                let flags = source.data
                // 文件被删除或重命名 → 停止当前 watcher，尝试重建
                if flags.contains(.delete) || flags.contains(.rename) {
                    #if DEBUG
                    dlog("[relay] JSONL 文件被删除/重命名: surface \(surfaceID.prefix(8))，尝试重建 watcher")
                    #endif
                    self.stopWatchingClaudeSync(surfaceID: surfaceID)
                    // 延迟重建，等文件系统稳定
                    self.watcherQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.rebuildWatcherIfNeeded(surfaceID: surfaceID)
                    }
                    return
                }
                self.handleJsonlChange(surfaceID: surfaceID, path: jsonlPath)
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
        invalidateClaudeHistorySnapshot(path: path)
        #if DEBUG
        dlog("[relay] 停止监听 JSONL: surface \(surfaceID.prefix(8))")
        #endif
    }

    /// 文件被删除/重命名后尝试重建 watcher（必须在 watcherQueue 上调用）
    private func rebuildWatcherIfNeeded(surfaceID: String) {
        // 确认还没被其他逻辑重建
        guard watchedSurfaces[surfaceID] == nil else { return }

        // 重新定位 JSONL 文件
        guard let sessionId = lookupSessionId(forSurface: surfaceID),
              Self.isValidID(sessionId) else {
            #if DEBUG
            dlog("[relay] rebuildWatcher: session 未找到，放弃重建 surface \(surfaceID.prefix(8))")
            #endif
            return
        }
        let cwd = getSurfaceCwd(surfaceID: surfaceID) ?? ""
        let projectDir = claudeProjectPath(forCwd: cwd)
        let newPath = "\(projectDir)/\(sessionId).jsonl"
        guard FileManager.default.fileExists(atPath: newPath) else {
            #if DEBUG
            dlog("[relay] rebuildWatcher: JSONL 文件不存在，放弃重建 surface \(surfaceID.prefix(8))")
            #endif
            return
        }

        let fd = Darwin.open(newPath, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else { return }

        let fileAttrs = try? FileManager.default.attributesOfItem(atPath: newPath)
        let currentSize = (fileAttrs?[.size] as? UInt64) ?? 0

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: watcherQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.stopWatchingClaudeSync(surfaceID: surfaceID)
                self.watcherQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.rebuildWatcherIfNeeded(surfaceID: surfaceID)
                }
                return
            }
            self.handleJsonlChange(surfaceID: surfaceID, path: newPath)
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        jsonlWatchers[newPath] = (fd, source, currentSize)
        watchedSurfaces[surfaceID] = newPath
        source.resume()

        // 通知手机端会话文件已变更，需重新加载
        pushEvent("claude.session.reset", payload: ["surface_id": surfaceID])

        #if DEBUG
        dlog("[relay] rebuildWatcher: 成功重建 watcher surface \(surfaceID.prefix(8))")
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
            // 清空整个缓存 + inflight，唤醒所有等待者
            self.claudeHistoryCacheLock.lock()
            self.claudeHistoryCache.removeAll()
            let pendingConditions = Array(self.claudeHistoryInflight.values)
            self.claudeHistoryInflight.removeAll()
            self.claudeHistoryCacheLock.unlock()
            // broadcast 放在锁外，避免多锁嵌套
            for condition in pendingConditions {
                condition.lock()
                condition.broadcast()
                condition.unlock()
            }
        }
    }

    /// 文件变化时读取增量内容并推送
    private func handleJsonlChange(surfaceID: String, path: String) {
        guard var watcher = jsonlWatchers[path] else { return }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let newSize = (attrs?[.size] as? UInt64) ?? 0

        // 文件被截断（新会话覆盖）→ 重置偏移量，从头读取
        if newSize < watcher.lastSize {
            #if DEBUG
            dlog("[relay] JSONL 文件被截断: \(path.components(separatedBy: "/").last ?? "?") (\(watcher.lastSize) → \(newSize))，从头读取")
            #endif
            watcher.lastSize = 0
            jsonlWatchers[path] = watcher
            invalidateClaudeHistorySnapshot(path: path)
            // 通知手机端清空旧消息，重新加载
            pushEvent("claude.session.reset", payload: ["surface_id": surfaceID])
        }

        // 文件没有变大，跳过
        guard newSize > watcher.lastSize else { return }
        invalidateClaudeHistorySnapshot(path: path)

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

        // 阶段变化时推送 phase.update 事件
        if status != lastReportedPhase {
            lastReportedPhase = status
            // 提取最近的用户消息和助手回复用于推送摘要
            let lastUser = newMessages.last(where: { ($0["type"] as? String) == "user" })
            let lastUserText = (lastUser?["content"] as? [[String: Any]])?
                .first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            let lastAssistant = newMessages.last(where: { ($0["type"] as? String) == "assistant" })
            let lastAssistantText = (lastAssistant?["content"] as? [[String: Any]])?
                .first(where: { ($0["type"] as? String) == "text" })?["text"] as? String

            pushPhaseEvent(
                phase: status,
                surfaceID: surfaceID,
                toolName: nil,
                projectName: getSurfaceCwd(surfaceID: surfaceID)?.components(separatedBy: "/").last,
                lastUserMessage: lastUserText,
                lastAssistantSummary: lastAssistantText
            )
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
