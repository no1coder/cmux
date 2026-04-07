import CryptoKit
import Foundation

// MARK: - 连接状态

/// WebSocket 连接状态
enum ConnectionStatus {
    case connected
    case connecting
    case disconnected
}

// MARK: - RelayClient

/// 通过 WebSocket 连接中继服务器的客户端
/// - 地址格式：wss://{serverURL}/ws/device/{deviceID}
/// - 支持认证握手、心跳保活、指数退避自动重连
final class RelayClient: NSObject {

    // MARK: - 公开回调

    /// 收到服务器消息时触发
    var onMessage: ((Data) -> Void)?

    /// 连接状态变化时触发
    var onStatusChange: ((ConnectionStatus) -> Void)?

    // MARK: - 私有属性

    private let serverURL: String
    private let deviceID: String
    private let pairSecret: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    /// 心跳定时器（每 30 秒发一次 ping）
    private var heartbeatTimer: Timer?

    /// 重连延迟（秒），范围 1...60，每次失败后翻倍
    private var reconnectDelay: TimeInterval = 1.0
    private let reconnectDelayMax: TimeInterval = 60.0
    private let reconnectDelayBase: TimeInterval = 1.0

    /// 是否主动断开（用于区分主动 stop 和异常断开）
    private var intentionalDisconnect = false

    /// 串行队列，用于保护 webSocketTask / reconnectDelay / status / intentionalDisconnect 等共享状态
    private let stateQueue = DispatchQueue(label: "com.cmux.relay.client.state")

    /// 当前连接状态
    private(set) var status: ConnectionStatus = .disconnected {
        didSet {
            if status != oldValue {
                onStatusChange?(status)
            }
        }
    }

    // MARK: - 初始化

    init(serverURL: String, deviceID: String, pairSecret: String) {
        self.serverURL = serverURL
        self.deviceID = deviceID
        self.pairSecret = pairSecret
        super.init()
    }

    // MARK: - 公开接口

    /// 开始连接（或重连）
    func start() {
        intentionalDisconnect = false
        reconnectDelay = reconnectDelayBase
        connect()
    }

    /// 主动断开连接
    func stop() {
        intentionalDisconnect = true
        stopHeartbeat()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        status = .disconnected
    }

    /// 发送数据到服务器
    func send(_ data: Data) {
        guard let task = webSocketTask, status == .connected else { return }
        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { [weak self] error in
            if let error {
                self?.handleConnectionFailure(error: error)
            }
        }
    }

    // MARK: - 连接管理

    private func connect() {
        guard !intentionalDisconnect else { return }

        status = .connecting

        // 构造 WebSocket URL
        let urlString = "wss://\(serverURL)/ws/device/\(deviceID)"
        guard let url = URL(string: urlString) else {
            scheduleReconnect()
            return
        }

        // 先释放旧 session，避免泄漏
        urlSession?.invalidateAndCancel()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.urlSession = session
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // 开始读取消息循环
        receiveNextMessage()

        // 发起认证握手
        performAuthHandshake()
    }

    // MARK: - 认证握手

    /// 认证流程：
    /// 1. 服务器发送 auth_challenge（含 nonce）
    /// 2. 客户端计算 HMAC-SHA256(SHA256(pair_secret), deviceID+nonce+timestamp) 并发送
    /// 3. 等待服务器返回 auth_ok
    private func performAuthHandshake() {
        guard let task = webSocketTask else { return }

        // 接收 auth_challenge
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleConnectionFailure(error: error)
            case .success(let message):
                self.handleAuthChallenge(message: message)
            }
        }
    }

    private func handleAuthChallenge(message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d):
            data = d
        case .string(let s):
            guard let d = s.data(using: .utf8) else {
                handleConnectionFailure(error: RelayClientError.invalidMessage)
                return
            }
            data = d
        @unknown default:
            handleConnectionFailure(error: RelayClientError.invalidMessage)
            return
        }

        // 解析 auth_challenge
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type_ = json["type"] as? String, type_ == "auth_challenge",
              let nonce = json["nonce"] as? String else {
            handleConnectionFailure(error: RelayClientError.authFailed)
            return
        }

        // 计算 HMAC-SHA256（消息格式：deviceID:nonce:timestamp，与服务端一致）
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let message_ = deviceID + ":" + nonce + ":" + timestamp

        guard let hmacHex = computeHMAC(message: message_) else {
            handleConnectionFailure(error: RelayClientError.authFailed)
            return
        }

        // 发送认证响应（type 为 "auth"，字段与服务端协议对齐）
        let response: [String: Any] = [
            "type": "auth",
            "device_id": deviceID,
            "nonce": nonce,
            "timestamp": timestamp,
            "signature": hmacHex,
        ]

        guard let responseData = try? JSONSerialization.data(withJSONObject: response),
              let responseString = String(data: responseData, encoding: .utf8) else {
            handleConnectionFailure(error: RelayClientError.authFailed)
            return
        }

        webSocketTask?.send(.string(responseString)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.handleConnectionFailure(error: error)
                return
            }
            // 等待 auth_ok
            self.waitForAuthOK()
        }
    }

    private func waitForAuthOK() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleConnectionFailure(error: error)
            case .success(let message):
                let data: Data?
                switch message {
                case .data(let d): data = d
                case .string(let s): data = s.data(using: .utf8)
                @unknown default: data = nil
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "auth_ok" else {
                    self.handleConnectionFailure(error: RelayClientError.authFailed)
                    return
                }

                // 认证成功，更新状态并启动心跳
                self.status = .connected
                self.reconnectDelay = self.reconnectDelayBase
                self.startHeartbeat()
            }
        }
    }

    // MARK: - HMAC 计算

    /// 计算 HMAC-SHA256(SHA256(pair_secret), message)，返回十六进制字符串
    private func computeHMAC(message: String) -> String? {
        guard let secretData = pairSecret.data(using: .utf8),
              let messageData = message.data(using: .utf8) else {
            return nil
        }

        // key = SHA256(pair_secret)
        let keyDigest = SHA256.hash(data: secretData)
        let keyData = Data(keyDigest)

        // HMAC-SHA256(key, message)
        let key = SymmetricKey(data: keyData)
        let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: key)
        return Data(mac).hexString
    }

    // MARK: - 消息接收循环

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // 仅在已连接状态下报告错误（握手阶段由 handshake 自己处理）
                if self.status == .connected {
                    self.handleConnectionFailure(error: error)
                }
            case .success(let message):
                if self.status == .connected {
                    let data: Data?
                    switch message {
                    case .data(let d): data = d
                    case .string(let s): data = s.data(using: .utf8)
                    @unknown default: data = nil
                    }
                    if let data {
                        self.onMessage?(data)
                    }
                }
                // 继续接收下一条消息
                self.receiveNextMessage()
            }
        }
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        stopHeartbeat()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: 30,
                repeats: true
            ) { [weak self] _ in
                self?.sendPing()
            }
        }
    }

    private func stopHeartbeat() {
        DispatchQueue.main.async { [weak self] in
            self?.heartbeatTimer?.invalidate()
            self?.heartbeatTimer = nil
        }
    }

    private func sendPing() {
        webSocketTask?.sendPing { [weak self] error in
            if let error {
                self?.handleConnectionFailure(error: error)
            }
        }
    }

    // MARK: - 错误处理与重连

    private func handleConnectionFailure(error: Error) {
        guard !intentionalDisconnect else { return }

        stopHeartbeat()
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        status = .disconnected

        scheduleReconnect()
    }

    /// 指数退避重连（1s → 2s → 4s → ... → 60s）
    private func scheduleReconnect() {
        guard !intentionalDisconnect else { return }

        let delay = reconnectDelay
        // 下次翻倍，不超过上限
        reconnectDelay = min(reconnectDelay * 2, reconnectDelayMax)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect else { return }
            self.connect()
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RelayClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // 握手完成后由 performAuthHandshake 处理状态切换
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard !intentionalDisconnect else { return }
        handleConnectionFailure(error: RelayClientError.connectionClosed(closeCode))
    }
}

// MARK: - 错误类型

enum RelayClientError: Error {
    case invalidURL
    case invalidMessage
    case authFailed
    case connectionClosed(URLSessionWebSocketTask.CloseCode)
}

// MARK: - Data 扩展

private extension Data {
    /// 将 Data 转为小写十六进制字符串
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
