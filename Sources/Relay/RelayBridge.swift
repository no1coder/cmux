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

    // MARK: - Unix Socket I/O

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
