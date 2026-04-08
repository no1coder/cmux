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
        guard let payload = envelope["payload"] as? [String: Any] else {
            // 非 RPC 消息（如 resume），忽略
            return
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
                self.handleReadScreen(surfaceID: surfaceID, requestID: requestID)
            }

        // Claude JSONL 消息读取（直接从 Claude Code 会话文件读取，不解析终端）
        case "claude.messages":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let surfaceID = params?["surface_id"] as? String ?? ""
                let afterSeq = params?["after_seq"] as? Int ?? 0
                let result = self.readClaudeMessages(surfaceID: surfaceID, afterSeq: afterSeq)
                self.sendRPCResponse(requestID: requestID, result: result)
            }

        // 其他终端命令（转发到本地 Unix socket，V2 API 内部通过 surface_id 定位 workspace）
        default:
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.forwardToSocket(method: method, params: params, requestID: requestID)
            }
        }
    }

    // MARK: - 转发到本地 Socket

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
    /// 如果目标 surface 不在当前 workspace，先自动切换
    private func handleReadScreen(surfaceID: String, requestID: Int) {
        guard !surfaceID.isEmpty else {
            sendRPCResponse(requestID: requestID, result: ["error": "缺少 surface_id"])
            return
        }

        // 尝试读取，如果失败（surface 不在当前 workspace），切换后重试
        var response = sendV1Command("read_screen \(surfaceID)")

        if response == nil || response?.hasPrefix("ERROR") == true {
            // 尝试找到 surface 所在的 workspace 并切换
            if switchToWorkspaceContaining(surfaceID: surfaceID) {
                response = sendV1Command("read_screen \(surfaceID)")
            }
        }

        guard let response, !response.hasPrefix("ERROR") else {
            sendRPCResponse(requestID: requestID, result: ["error": response ?? "socket 通信失败"])
            return
        }

        let lines = response.components(separatedBy: "\n")
        sendRPCResponse(requestID: requestID, result: [
            "lines": lines,
            "surface_id": surfaceID,
        ])
    }

    /// 切换到包含指定 surface 的 workspace
    /// 先用 workspace_id 参数查找（不切换），找到后只做一次 select
    /// - Returns: 是否成功切换
    private func switchToWorkspaceContaining(surfaceID: String) -> Bool {
        guard let wsResp = sendJsonRPC(method: "workspace.list", params: nil),
              let wsResult = wsResp["result"] as? [String: Any],
              let workspaces = wsResult["workspaces"] as? [[String: Any]] else {
            return false
        }

        // 先查找 surface 所在的 workspace（不切换）
        for ws in workspaces {
            guard let wsID = ws["id"] as? String,
                  (ws["selected"] as? Bool) != true else { continue }

            // 用 workspace_id 参数查询，不切换
            if let surfResp = sendJsonRPC(method: "surface.list", params: ["workspace_id": wsID]),
               let surfResult = surfResp["result"] as? [String: Any],
               let surfaces = surfResult["surfaces"] as? [[String: Any]],
               surfaces.contains(where: { ($0["id"] as? String) == surfaceID }) {
                // 找到了，只做一次 select
                _ = sendJsonRPC(method: "workspace.select", params: ["workspace_id": wsID])
                #if DEBUG
                dlog("[relay] 切换到 workspace \(wsID.prefix(8))... 以操作 surface \(surfaceID.prefix(8))...")
                #endif
                return true
            }
        }
        return false
    }

    // MARK: - 响应发送

    /// 发送 RPC 响应（Envelope 格式）回手机端
    private func sendRPCResponse(requestID: Int, result: [String: Any]) {
        #if DEBUG
        dlog("[relay] sendRPCResponse id=\(requestID) keys=\(result.keys.sorted()) client=\(relayClient != nil) connected=\(relayClient?.status == .connected)")
        #endif
        var responsePayload = result
        responsePayload["id"] = requestID

        let envelope: [String: Any] = [
            "seq": 0,
            "ts": Int64(Date().timeIntervalSince1970),
            "from": "mac",
            "type": "rpc_response",
            "payload": responsePayload,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            return
        }
        relayClient?.send(data)
    }

    // MARK: - 出站事件推送（Mac → iOS）

    /// 推送 Mac 端产生的事件到手机（Envelope 格式）
    func pushEvent(_ eventType: String, payload: [String: Any]) {
        #if DEBUG
        dlog("[relay] pushEvent: \(eventType), relayClient=\(relayClient != nil)")
        #endif
        var eventPayload = payload
        eventPayload["event"] = eventType

        let envelope: [String: Any] = [
            "seq": 0,
            "ts": Int64(Date().timeIntervalSince1970),
            "from": "mac",
            "type": "event",
            "payload": eventPayload,
        ]

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

    /// 发送 JSON-RPC 请求并返回解析后的响应
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
    func sendV1Command(_ command: String) -> String? {
        return sendToUnixSocket(command)
    }

    /// 发送 JSON 字符串到本地 Unix socket，返回响应字符串
    func sendToUnixSocket(_ json: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
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
        guard connectResult == 0 else { return nil }

        let payload = json + "\n"
        guard let payloadData = payload.data(using: .utf8) else { return nil }

        let sendResult = payloadData.withUnsafeBytes { ptr in
            Foundation.send(fd, ptr.baseAddress!, ptr.count, 0)
        }
        guard sendResult == payloadData.count else { return nil }

        // 读取响应（增大缓冲区到 64KB）
        var responseBuffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 65536)

        while true {
            let bytesRead = recv(fd, &readBuf, readBuf.count, 0)
            if bytesRead <= 0 { break }
            responseBuffer.append(contentsOf: readBuf[..<bytesRead])
            if responseBuffer.contains(UInt8(ascii: "\n")) { break }
        }

        return String(data: responseBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .newlines)
    }

    // MARK: - Claude JSONL 消息读取

    /// 从 Claude Code 的 JSONL 会话文件读取结构化消息
    /// 跟 happy 项目的 sessionScanner 一样，直接读文件而非解析终端
    private func readClaudeMessages(surfaceID: String, afterSeq: Int) -> [String: Any] {
        // 1. 先从 session store 精确匹配 surfaceId → sessionId
        let jsonlPath: String
        if let sessionId = lookupSessionId(forSurface: surfaceID) {
            // 精确匹配：从 session store 获取 session ID
            let cwd = getSurfaceCwd(surfaceID: surfaceID) ?? ""
            let projectDir = claudeProjectPath(forCwd: cwd)
            let path = "\(projectDir)/\(sessionId).jsonl"
            if FileManager.default.fileExists(atPath: path) {
                jsonlPath = path
            } else {
                // session store 有映射但 JSONL 不存在 — 新会话还没写入，返回空
                // 不要回退到旧文件，那属于不同的会话
                return ["messages": [] as [Any], "session_file": "\(sessionId).jsonl", "total_seq": 0]
            }
        } else {
            // 没有 session store 记录，回退到按 CWD + 最新修改时间
            guard let fallback = findLatestJsonlByCwd(surfaceID: surfaceID) else {
                return ["error": "无法定位会话文件（缺少 session store 和 CWD）", "messages": []]
            }
            jsonlPath = fallback
        }

        let fm = FileManager.default

        // 4. 读取并解析 JSONL
        guard let data = fm.contents(atPath: jsonlPath),
              let content = String(data: data, encoding: .utf8) else {
            return ["error": "无法读取会话文件", "messages": []]
        }

        let lines = content.components(separatedBy: "\n")
        var messages: [[String: Any]] = []
        var seq = 0

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

        return [
            "messages": messages,
            "session_file": jsonlPath.components(separatedBy: "/").last ?? "",
            "total_seq": seq,
            "status": status,
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
}
