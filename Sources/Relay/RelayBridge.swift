import Foundation

// MARK: - RelayBridge

/// 将 WebSocket 消息桥接到本地 cmux Unix socket（JSON-RPC）
/// 负责：解析 WebSocket 信封 → 转发到本地 socket → 包装响应回传
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

    /// 处理来自 RelayClient 的原始 Data
    /// - 解析信封，提取 JSON-RPC payload
    /// - 发送到本地 Unix socket，读取响应
    /// - 包装响应并通过 relay 回传
    func handleIncoming(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // 提取请求信封字段
        guard let requestID = envelope["id"] as? String,
              let payload = envelope["payload"] else {
            return
        }

        // 检查是否是代理审批响应消息（agent.approve / agent.reject）
        // 这类消息不转发到本地 socket，而是由 agentApproval 处理
        if let payloadDict = payload as? [String: Any],
           let method = payloadDict["method"] as? String,
           method == "agent.approve" || method == "agent.reject" {
            let approved = method == "agent.approve"
            let params = payloadDict["params"] as? [String: Any]
            let approvalRequestID = params?["request_id"] as? String ?? requestID

            agentApproval?.handleApprovalResponse(requestID: approvalRequestID, approved: approved)

            // 回传成功响应信封
            let successEnvelope: [String: Any] = [
                "id": requestID,
                "payload": ["ok": true],
            ]
            if let outData = try? JSONSerialization.data(withJSONObject: successEnvelope) {
                relayClient?.send(outData)
            }
            return
        }

        // 检查是否是文件/浏览器操作消息（file.list / file.read / browser.screenshot）
        // 这类消息由本地处理器处理，不转发到 Unix socket
        // 在后台线程执行，避免阻塞入站消息处理（与 Unix socket 转发路径保持一致）
        if let payloadDict = payload as? [String: Any],
           let method = payloadDict["method"] as? String,
           method == "file.list" || method == "file.read" || method == "browser.screenshot" {
            let params = payloadDict["params"] as? [String: Any]
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let resultPayload = self.handleLocalMethod(method: method, params: params)
                let responseEnvelope: [String: Any] = [
                    "id": requestID,
                    "payload": resultPayload,
                ]
                if let outData = try? JSONSerialization.data(withJSONObject: responseEnvelope) {
                    self.relayClient?.send(outData)
                }
            }
            return
        }

        // 将 payload 序列化为 JSON-RPC 请求
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let payloadString = String(data: payloadData, encoding: .utf8) else {
            return
        }

        // 通过 Unix socket 发送并读取响应（在后台线程执行，避免阻塞）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let responseString = self.sendToUnixSocket(payloadString)
            let responseData = responseString?.data(using: .utf8)

            // 包装响应信封并回传
            let responsePayload: Any
            if let responseData,
               let parsed = try? JSONSerialization.jsonObject(with: responseData) {
                responsePayload = parsed
            } else {
                // 无响应或解析失败时返回空对象
                responsePayload = [String: Any]()
            }

            let responseEnvelope: [String: Any] = [
                "id": requestID,
                "payload": responsePayload,
            ]

            guard let outData = try? JSONSerialization.data(withJSONObject: responseEnvelope) else {
                return
            }
            self.relayClient?.send(outData)
        }
    }

    // MARK: - 出站事件推送（Mac → iOS）

    /// 推送 Mac 端产生的事件到手机
    func pushEvent(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else {
            return
        }
        relayClient?.send(data)
    }

    // MARK: - 本地方法路由

    /// 路由文件/浏览器操作方法到对应处理器
    /// - Parameters:
    ///   - method: 方法名（file.list / file.read / browser.screenshot）
    ///   - params: 请求参数
    /// - Returns: 响应字典
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
    /// - 适用于非 JSON-RPC 的 V1 文本协议命令（如 screenshot、read_screen）
    /// - 命令格式：纯文本 + 换行符；响应格式：`OK ...` 或 `ERROR ...`
    func sendV1Command(_ command: String) -> String? {
        return sendToUnixSocket(command)
    }

    /// 发送 JSON 字符串到本地 Unix socket，返回响应字符串
    /// - 使用 AF_UNIX SOCK_STREAM，发送内容 + 换行符，读取响应直到换行
    func sendToUnixSocket(_ json: String) -> String? {
        // 创建 socket fd
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // 构造 sockaddr_un
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

        // 连接
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        // 发送 JSON + 换行
        let payload = json + "\n"
        guard let payloadData = payload.data(using: .utf8) else { return nil }

        let sendResult = payloadData.withUnsafeBytes { ptr in
            Foundation.send(fd, ptr.baseAddress!, ptr.count, 0)
        }
        guard sendResult == payloadData.count else { return nil }

        // 读取响应直到换行符
        var responseBuffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 4096)

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
