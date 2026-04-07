import Foundation

// MARK: - RelayScreenStream

/// 定期读取终端屏幕内容，将变化推送到中继
/// - 通过 Unix socket 读取屏幕（`read_screen {surfaceID}`）
/// - 对比上次快照，有变化时通过 RelayBridge.pushEvent 推送
final class RelayScreenStream {

    // MARK: - 属性

    /// 关联的 RelayBridge（用于推送屏幕事件）
    weak var bridge: RelayBridge?

    /// 推流间隔（秒），范围 0.5...5.0
    private(set) var interval: TimeInterval = 1.0

    /// 每个 surface 的定时器
    private var timers: [String: DispatchSourceTimer] = [:]

    /// 每个 surface 的最后一次快照（行数组），用于差异检测
    private var lastSnapshots: [String: [String]] = [:]

    /// 并发保护锁
    private let lock = NSLock()

    /// Unix socket 路径（由 startStreaming 提供）
    private var socketPaths: [String: String] = [:]

    // MARK: - 公开接口

    /// 开始对指定 surface 推流
    /// - Parameters:
    ///   - surfaceID: 终端 surface 标识
    ///   - socketPath: 本地 cmux Unix socket 路径
    func startStreaming(surfaceID: String, socketPath: String) {
        lock.lock()
        defer { lock.unlock() }

        // 先停止已有的定时器
        stopTimer(for: surfaceID)

        socketPaths[surfaceID] = socketPath

        // 创建后台定时器
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.tick(surfaceID: surfaceID)
        }
        timers[surfaceID] = timer
        timer.resume()
    }

    /// 停止对指定 surface 推流
    func stopStreaming(surfaceID: String) {
        lock.lock()
        defer { lock.unlock() }
        stopTimer(for: surfaceID)
        lastSnapshots.removeValue(forKey: surfaceID)
        socketPaths.removeValue(forKey: surfaceID)
    }

    /// 停止所有 surface 的推流
    func stopAll() {
        lock.lock()
        defer { lock.unlock() }
        for key in timers.keys {
            stopTimer(for: key)
        }
        lastSnapshots.removeAll()
        socketPaths.removeAll()
    }

    /// 设置推流间隔，会被夹在 0.5...5.0 秒范围内
    func setInterval(_ seconds: TimeInterval) {
        let clamped = min(max(seconds, 0.5), 5.0)
        lock.lock()
        let changed = clamped != interval
        interval = clamped
        let surfaceIDs = changed ? Array(timers.keys) : []
        let paths = socketPaths
        lock.unlock()

        // 间隔改变时重启所有定时器以使新间隔生效
        if changed {
            for surfaceID in surfaceIDs {
                if let path = paths[surfaceID] {
                    startStreaming(surfaceID: surfaceID, socketPath: path)
                }
            }
        }
    }

    // MARK: - 定时器触发

    private func tick(surfaceID: String) {
        lock.lock()
        let socketPath = socketPaths[surfaceID]
        lock.unlock()

        guard let socketPath else { return }

        // 通过 Unix socket 读取屏幕内容
        guard let content = readScreen(surfaceID: surfaceID, socketPath: socketPath) else {
            return
        }

        // 将 base64 解码为文本行
        guard let decoded = Data(base64Encoded: content),
              let text = String(data: decoded, encoding: .utf8) else {
            return
        }
        let lines = text.components(separatedBy: "\n")

        lock.lock()
        let previous = lastSnapshots[surfaceID]
        let hasChanged = previous != lines
        if hasChanged {
            lastSnapshots[surfaceID] = lines
        }
        lock.unlock()

        guard hasChanged else { return }

        // 推送 screen.snapshot 事件
        let payload: [String: Any] = [
            "surface_id": surfaceID,
            "lines": lines,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        bridge?.pushEvent("screen.snapshot", payload: payload)
    }

    // MARK: - 读取屏幕

    /// 发送 `read_screen {surfaceID}` 到 Unix socket，解析 `OK {base64}` 响应
    private func readScreen(surfaceID: String, socketPath: String) -> String? {
        let command = "read_screen \(surfaceID)"

        // 优先复用已有的 bridge；若 bridge 不可用则直接用 socketPath 创建临时实例
        // 避免在高频 tick 中每次分配新的 RelayBridge
        let response: String?
        if let existingBridge = bridge {
            response = existingBridge.sendToUnixSocket(command)
        } else {
            // bridge 已释放时的兜底路径（不常见）
            let fallback = RelayBridge(socketPath: socketPath)
            response = fallback.sendToUnixSocket(command)
        }

        guard let response else { return nil }

        // 格式：`OK {base64}` 或 `ERROR ...`
        guard response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3))
            .trimmingCharacters(in: .whitespaces)
        return base64.isEmpty ? nil : base64
    }

    // MARK: - 内部辅助

    /// 停止并移除指定 surfaceID 的定时器（调用前需持有 lock）
    private func stopTimer(for surfaceID: String) {
        if let timer = timers.removeValue(forKey: surfaceID) {
            timer.cancel()
        }
    }
}
