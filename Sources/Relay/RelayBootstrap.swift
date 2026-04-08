import Bonsplit
import Foundation

// Relay 模块启动入口
// 在 AppDelegate.applicationDidFinishLaunching 中调用 RelayBootstrap.shared.start(socketPath:)
final class RelayBootstrap {
    static let shared = RelayBootstrap()

    private(set) var client: RelayClient?
    private(set) var bridge: RelayBridge?
    private(set) var screenStream: RelayScreenStream?
    private(set) var agentApproval: RelayAgentApproval?
    /// Mac 本地操作通知观察者
    private var localObservers: [NSObjectProtocol] = []

    private init() {}

    /// 启动 Relay 模块
    /// - Parameter socketPath: cmux 本地 Unix socket 路径
    func start(socketPath: String) {
        #if DEBUG
        dlog("[relay] start() 被调用，socketPath=\(socketPath)")
        dlog("[relay] isEnabled=\(RelaySettings.isEnabled) serverURL=\(RelaySettings.serverURL ?? "nil") phoneID=\(RelaySettings.pairedPhoneID ?? "nil")")
        #endif

        guard RelaySettings.isEnabled else {
            #if DEBUG
            dlog("[relay] 远程访问未启用，跳过")
            #endif
            return
        }

        guard let serverURL = RelaySettings.serverURL, !serverURL.isEmpty else {
            #if DEBUG
            dlog("[relay] 未配置中继服务器地址，跳过")
            #endif
            return
        }

        guard let phoneID = RelaySettings.pairedPhoneID,
              let pairSecret = RelaySettings.loadPairSecret(forPhone: phoneID)
        else {
            #if DEBUG
            dlog("[relay] 未配对，跳过连接（等待配对后手动调用 start）")
            #endif
            return
        }

        // 初始化各模块
        let relayClient = RelayClient(serverURL: serverURL, deviceID: RelaySettings.deviceID, pairSecret: pairSecret)
        let relayBridge = RelayBridge(socketPath: socketPath)
        let relayScreenStream = RelayScreenStream()
        let relayAgentApproval = RelayAgentApproval(bridge: relayBridge)

        // 配置文件处理器（沙箱限制为用户常用工作目录）
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let sandbox = RelayFileSandbox(allowedRoots: [
            "\(homeDir)/code",
            "\(homeDir)/projects",
            "\(homeDir)/Developer",
            "\(homeDir)/Documents",
            "\(homeDir)/Desktop",
        ])
        let fileHandler = RelayFileHandler(sandbox: sandbox)
        let browserHandler = RelayBrowserHandler(bridge: relayBridge)

        // 连接各模块
        relayBridge.relayClient = relayClient
        relayBridge.agentApproval = relayAgentApproval
        relayBridge.fileHandler = fileHandler
        relayBridge.browserHandler = browserHandler
        relayScreenStream.bridge = relayBridge

        // RelayClient 收到消息时，交给 Bridge 处理
        relayClient.onMessage = { [weak relayBridge] data in
            relayBridge?.handleIncoming(data)
        }

        // Issue 3: 连接状态变化时发送通知，供 UI 层实时刷新
        relayClient.onStatusChange = { [weak relayBridge] (status: ConnectionStatus) in
            let statusString: String
            switch status {
            case .connected: statusString = "connected"
            case .connecting: statusString = "connecting"
            case .disconnected: statusString = "disconnected"
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .relayConnectionStatusDidChange,
                    object: nil,
                    userInfo: ["status": statusString]
                )
            }

            // 连接成功后，主动推送 surface 和 workspace 列表给手机
            if status == .connected {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                    relayBridge?.pushSurfaceList()
                    relayBridge?.pushWorkspaceList()
                }
            }

            #if DEBUG
            dlog("[relay] 连接状态: \(status)")
            #endif
        }

        // 保存引用
        self.client = relayClient
        self.bridge = relayBridge
        self.screenStream = relayScreenStream
        self.agentApproval = relayAgentApproval

        // 监听 Mac 本地操作，自动推送 surface 列表到手机
        observeLocalChanges(bridge: relayBridge)

        // 连接到中继服务器
        relayClient.start()

        #if DEBUG
        dlog("[relay] Relay 模块已启动，连接到 \(serverURL)")
        #endif
    }

    /// 监听 Mac 端 tab/surface 变化，自动推送更新到手机
    /// 安全：collectAllSurfaces 已不再切换 workspace
    private func observeLocalChanges(bridge: RelayBridge) {
        for observer in localObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        localObservers.removeAll()

        // 防抖：每次事件后 0.5 秒推送，连续事件取消前一次
        let lock = NSLock()
        var pendingWork: DispatchWorkItem?

        let debouncedPush = { [weak bridge] in
            lock.lock()
            pendingWork?.cancel()
            let work = DispatchWorkItem { bridge?.pushSurfaceList() }
            pendingWork = work
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        // Tab 焦点变化（创建/关闭/切换 tab 后触发）
        localObservers.append(
            NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusTab, object: nil, queue: nil
            ) { _ in debouncedPush() }
        )

        // Surface 焦点变化（创建/关闭/切换 pane 后触发）
        localObservers.append(
            NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface, object: nil, queue: nil
            ) { _ in debouncedPush() }
        )
    }

    /// 停止 Relay 模块
    func stop() {
        for observer in localObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        localObservers.removeAll()

        screenStream?.stopAll()
        client?.stop()
        client = nil
        bridge = nil
        screenStream = nil
        agentApproval = nil

        #if DEBUG
        dlog("[relay] Relay 模块已停止")
        #endif
    }
}
