import Foundation

// MARK: - RelayAgentApproval

/// 桥接结构化审批请求：iOS 端 ↔ 本地终端
/// - 代理请求权限时，推送审批请求到 iOS
/// - iOS 发送 agent.approve 或 agent.reject 时，向对应 surface 注入 y/n
final class RelayAgentApproval {

    // MARK: - 属性

    private let bridge: RelayBridge

    /// 待处理的审批请求，key 为 request_id
    private var pendingRequests: [String: PendingApproval] = [:]

    /// 请求 ID 自增计数器
    private var requestCounter = 0

    /// 并发保护锁
    private let lock = NSLock()

    // MARK: - 数据结构

    struct PendingApproval {
        let requestID: String
        let surfaceID: String
        let timestamp: Date
        let timeoutSeconds: Int
    }

    // MARK: - 初始化

    init(bridge: RelayBridge) {
        self.bridge = bridge
    }

    // MARK: - 公开接口

    /// 代理请求权限时调用（来自 TerminalController 通知）
    /// - Parameters:
    ///   - surfaceID: 终端 surface 标识
    ///   - agent: 代理名称（如 "claude", "codex"）
    ///   - action: 请求的操作描述
    ///   - context: 附加上下文信息
    func reportApprovalRequest(surfaceID: String, agent: String, action: String, context: String) {
        // 生成唯一 request_id
        lock.lock()
        requestCounter += 1
        let counter = requestCounter
        lock.unlock()

        let requestID = "approval-\(counter)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let timeoutSeconds = 300 // 5 分钟超时

        let approval = PendingApproval(
            requestID: requestID,
            surfaceID: surfaceID,
            timestamp: Date(),
            timeoutSeconds: timeoutSeconds
        )

        lock.lock()
        pendingRequests[requestID] = approval
        lock.unlock()

        // 推送审批请求事件到 iOS
        let payload: [String: Any] = [
            "request_id": requestID,
            "surface_id": surfaceID,
            "agent": agent,
            "action": action,
            "context": context,
            "timeout_seconds": timeoutSeconds,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        bridge.pushEvent("agent.approval_required", payload: payload)

        // 启动超时定时器（5 分钟后自动拒绝）
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(timeoutSeconds)
        ) { [weak self] in
            self?.handleTimeout(requestID: requestID)
        }
    }

    /// iOS 发送 agent.approve 或 agent.reject 时调用
    /// - Parameters:
    ///   - requestID: 审批请求 ID
    ///   - approved: true 表示批准，false 表示拒绝
    func handleApprovalResponse(requestID: String, approved: Bool) {
        lock.lock()
        let approval = pendingRequests.removeValue(forKey: requestID)
        lock.unlock()

        guard let approval else {
            // 已超时或已处理，忽略
            return
        }

        // 向对应 surface 发送 "y\n" 或 "n\n"
        let text = approved ? "y\n" : "n\n"
        sendTextToSurface(surfaceID: approval.surfaceID, text: text)

        // 推送审批结果事件到 iOS
        let resolvedPayload: [String: Any] = [
            "request_id": requestID,
            "surface_id": approval.surfaceID,
            "approved": approved,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        bridge.pushEvent("agent.approval_resolved", payload: resolvedPayload)
    }

    // MARK: - 私有方法

    /// 超时后自动拒绝
    private func handleTimeout(requestID: String) {
        // 原子地从 pendingRequests 中移除，避免与 handleApprovalResponse 产生竞态
        lock.lock()
        let approval = pendingRequests.removeValue(forKey: requestID)
        lock.unlock()

        guard let approval else {
            // 已被响应处理，无需操作
            return
        }

        // 向对应 surface 发送拒绝（"n\n"），不再调用 handleApprovalResponse 以避免重复移除
        let text = "n\n"
        let rpcPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "surface.send_text",
            "params": [
                "surface_id": approval.surfaceID,
                "text": text,
            ],
            "id": UUID().uuidString,
        ]
        if let payloadData = try? JSONSerialization.data(withJSONObject: rpcPayload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                _ = self.bridge.sendToUnixSocket(payloadString)
            }
        }

        // 推送超时事件到 iOS
        let timeoutPayload: [String: Any] = [
            "request_id": requestID,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        bridge.pushEvent("agent.approval_timeout", payload: timeoutPayload)
    }

    /// 构造 JSON-RPC surface.send_text 请求并写入 Unix socket
    private func sendTextToSurface(surfaceID: String, text: String) {
        let rpcPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "surface.send_text",
            "params": [
                "surface_id": surfaceID,
                "text": text,
            ],
            "id": UUID().uuidString,
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: rpcPayload),
              let payloadString = String(data: payloadData, encoding: .utf8) else {
            return
        }

        // 在后台线程执行，避免阻塞
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.bridge.sendToUnixSocket(payloadString)
        }
    }
}
