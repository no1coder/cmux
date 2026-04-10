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
    /// 上次使用的 socketPath，供 stop 后重新 start 时复用
    private(set) var lastSocketPath: String?
    /// Mac 本地操作通知观察者
    private var localObservers: [NSObjectProtocol] = []

    private init() {}

    /// 启动 Relay 模块
    /// - Parameter socketPath: cmux 本地 Unix socket 路径
    func start(socketPath: String) {
        lastSocketPath = socketPath

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
        relayBridge.e2eCrypto = RelayE2ECrypto(pairSecret: pairSecret)
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

            // 连接成功后，主动推送初始状态到手机：
            // - capabilities.snapshot：可用 slash 命令列表（供 iPhone 动态渲染命令菜单）
            // - surface.list_update：当前所有终端 surface
            // - workspace.list_update：当前所有 workspace
            if status == .connected {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                    relayBridge?.pushCapabilities()
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

        // 注入通知转发：必须在 relayClient.start() 之前同步完成
        assert(Thread.isMainThread, "RelayBootstrap.start() 必须在主线程调用")
        MainActor.assumeIsolated {
            TerminalNotificationStore.shared.setRelayForwardHandler { [weak relayBridge] notification in
                relayBridge?.pushEvent(
                    "notification",
                    payload: [
                        "title": notification.title,
                        "body": notification.body,
                        "subtitle": notification.subtitle,
                        "tab_id": notification.tabId.uuidString,
                        "surface_id": notification.surfaceId?.uuidString ?? "",
                        "created_at": Int64(notification.createdAt.timeIntervalSince1970 * 1000),
                    ],
                    pushHint: [
                        "event": "notification",
                        // 安全：不在 pushHint 中暴露终端命令内容，仅发送通用提示文本
                        "summary": String(localized: "relay.pushHint.newNotification", defaultValue: "You have a new terminal notification"),
                    ]
                )
            }
        }

        // 连接到中继服务器（handler 注入已在上方完成）
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

        // 清除通知转发回调，避免悬挂闭包
        assert(Thread.isMainThread, "RelayBootstrap.stop() 必须在主线程调用")
        MainActor.assumeIsolated {
            TerminalNotificationStore.shared.setRelayForwardHandler(nil)
        }

        screenStream?.stopAll()
        bridge?.stopAllWatchers()
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
