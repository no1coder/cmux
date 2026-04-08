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

        // workspace.create：创建后推送更新的列表
        case "workspace.create":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.forwardToSocket(method: method, params: params, requestID: requestID)
                // 创建成功后推送更新的 surface 列表
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

        // 终端输入命令（需要自动切换 workspace）
        case "surface.send_text", "surface.send_key":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                // 确保切换到目标 surface 所在的 workspace
                if let surfaceID = params?["surface_id"] as? String, !surfaceID.isEmpty {
                    _ = self.switchToWorkspaceContaining(surfaceID: surfaceID)
                }
                self.forwardToSocket(method: method, params: params, requestID: requestID)
            }

        // 其他终端命令（转发到本地 Unix socket）
        default:
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                self.forwardToSocket(method: method, params: params, requestID: requestID)
            }
        }
    }

    // MARK: - 转发到本地 Socket

    /// 将 RPC 请求转发到本地 cmux Unix socket，返回结果
    /// 如果请求包含 surface_id，会自动切换到对应 workspace
    private func forwardToSocket(method: String, params: [String: Any]?, requestID: Int) {
        // 如果请求中有 surface_id，确保切换到正确的 workspace
        if let surfaceID = params?["surface_id"] as? String {
            // 先尝试直接执行，失败再切换
            let testCmd = "read_screen \(surfaceID)"
            if let testResp = sendV1Command(testCmd), testResp.hasPrefix("ERROR") {
                _ = switchToWorkspaceContaining(surfaceID: surfaceID)
            }
        }
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
    /// - Returns: 是否成功切换
    private func switchToWorkspaceContaining(surfaceID: String) -> Bool {
        // 获取所有 workspace
        guard let wsResp = sendJsonRPC(method: "workspace.list", params: nil),
              let wsResult = wsResp["result"] as? [String: Any],
              let workspaces = wsResult["workspaces"] as? [[String: Any]] else {
            return false
        }

        // 遍历每个 workspace 查找目标 surface
        for ws in workspaces {
            guard let wsID = ws["id"] as? String,
                  (ws["selected"] as? Bool) != true else { continue }

            // 切换到这个 workspace
            _ = sendJsonRPC(method: "workspace.select", params: ["workspace_id": wsID])

            // 检查这个 workspace 是否包含目标 surface
            if let surfResp = sendJsonRPC(method: "surface.list", params: nil),
               let surfResult = surfResp["result"] as? [String: Any],
               let surfaces = surfResult["surfaces"] as? [[String: Any]] {
                if surfaces.contains(where: { ($0["id"] as? String) == surfaceID }) {
                    #if DEBUG
                    dlog("[relay] 切换到 workspace \(wsID.prefix(8))... 以读取 surface \(surfaceID.prefix(8))...")
                    #endif
                    return true
                }
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
    private func collectAllSurfaces() -> [[String: Any]] {
        guard let wsResp = sendJsonRPC(method: "workspace.list", params: nil),
              let wsResult = wsResp["result"] as? [String: Any],
              let workspaces = wsResult["workspaces"] as? [[String: Any]] else {
            return []
        }

        let currentWsID = workspaces.first { ($0["selected"] as? Bool) == true }?["id"] as? String
        var allSurfaces: [[String: Any]] = []

        for ws in workspaces {
            guard let wsID = ws["id"] as? String else { continue }
            // workspace 返回 title 和 current_directory 字段
            let wsTitle = ws["title"] as? String ?? ""
            let wsCwd = ws["current_directory"] as? String ?? ""
            // 优先使用 current_directory（目录路径），其次 title
            let wsName = wsCwd.isEmpty ? wsTitle : wsCwd
            let wsSelected = (ws["selected"] as? Bool) ?? false

            if !wsSelected {
                _ = sendJsonRPC(method: "workspace.select", params: ["workspace_id": wsID])
            }

            if let surfResp = sendJsonRPC(method: "surface.list", params: nil),
               let surfResult = surfResp["result"] as? [String: Any],
               let surfaces = surfResult["surfaces"] as? [[String: Any]] {
                for var surf in surfaces {
                    surf["workspace_id"] = wsID
                    surf["workspace_name"] = wsName
                    allSurfaces.append(surf)
                }
            }
        }

        if let currentWsID {
            _ = sendJsonRPC(method: "workspace.select", params: ["workspace_id": currentWsID])
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
}
