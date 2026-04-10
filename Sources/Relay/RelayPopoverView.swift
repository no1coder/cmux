import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - 通知名

extension Notification.Name {
    /// Relay 连接状态变化通知，userInfo 包含 "status" 键（ConnectionStatus 的描述字符串）
    static let relayConnectionStatusDidChange = Notification.Name("cmux.relayConnectionStatusDidChange")
}

// MARK: - Relay Popover 主视图

struct RelayPopoverView: View {
    @ObservedObject var stateModel: RelayStateModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "iphone")
                Text(String(localized: "relay.title", defaultValue: "手机远程访问"))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // 内容区域
            switch stateModel.viewState {
            case .unconfigured:
                unconfiguredView
            case .unpaired:
                unpairedView
            case .pairing:
                pairingView
            case .paired:
                pairedView
            }
        }
        .frame(width: 320)
    }

    // MARK: - 未配置（没有服务器地址）

    private var unconfiguredView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .padding(.top, 16)

            Text(String(localized: "relay.unconfigured.hint", defaultValue: "请输入中继服务器地址"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            serverURLField

            Button(String(localized: "relay.save", defaultValue: "保存")) {
                stateModel.saveServerURL()
            }
            .disabled(stateModel.serverURLInput.isEmpty)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 未配对

    private var unpairedView: some View {
        VStack(spacing: 12) {
            statusRow(
                String(localized: "relay.status.unpaired", defaultValue: "未配对"),
                color: .secondary
            )

            serverURLField

            if let error = stateModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .multilineTextAlignment(.center)
            }

            Divider()

            Button(action: { stateModel.generateQRCode() }) {
                Label(
                    String(localized: "relay.generateQR", defaultValue: "生成配对二维码"),
                    systemImage: "qrcode"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            Text(String(localized: "relay.pairing.hint", defaultValue: "使用 cmux 手机 App 扫码配对"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    // MARK: - 配对中（显示二维码）

    private var pairingView: some View {
        VStack(spacing: 12) {
            if let qrImage = stateModel.qrCodeImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(.top, 16)
                    .accessibilityLabel(String(localized: "relay.accessibility.qrCode", defaultValue: "Pairing QR Code"))
            } else {
                ProgressView()
                    .padding(.top, 16)
            }

            Text(String(localized: "relay.pairing.scan", defaultValue: "使用 cmux 手机 App 扫描"))
                .font(.callout)

            if stateModel.pairingTimeRemaining > 0 {
                Text(String(localized: "relay.pairing.expires", defaultValue: "\(stateModel.pairingTimeRemaining)秒后过期"))
                    .font(.caption)
                    .foregroundStyle(stateModel.pairingTimeRemaining < 60 ? .red : .secondary)
                    .monospacedDigit()
                    .accessibilityValue("\(stateModel.pairingTimeRemaining) seconds remaining")
            }

            if let error = stateModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(String(localized: "relay.cancel", defaultValue: "取消")) {
                stateModel.cancelPairing()
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - 已配对

    private var pairedView: some View {
        VStack(spacing: 0) {
            // 状态 + 设备信息
            VStack(spacing: 8) {
                statusRow(stateModel.connectionStatusText, color: stateModel.connectionStatusColor)

                if let phoneName = stateModel.pairedPhoneName {
                    HStack {
                        Text(String(localized: "relay.device", defaultValue: "设备"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(phoneName)
                    }
                    .font(.caption)
                    .padding(.horizontal, 16)
                }

                if let latency = stateModel.latencyMs, stateModel.isConnected {
                    HStack {
                        Text(String(localized: "relay.latency", defaultValue: "延迟"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(latency)ms")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)

            Divider()

            // 服务器地址（已配对时只读显示）
            HStack {
                Text(String(localized: "relay.server", defaultValue: "服务器"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stateModel.serverURLInput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // 允许访问的目录
            DisclosureGroup(
                String(localized: "relay.dirs.title", defaultValue: "允许访问的目录")
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(stateModel.allowedDirectories, id: \.self) { dir in
                        HStack {
                            Text(dir)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button {
                                stateModel.removeDirectory(dir)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    HStack {
                        TextField("~/path", text: $stateModel.newDirectoryInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .onSubmit { stateModel.addDirectory() }
                        Button {
                            stateModel.addDirectory()
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .disabled(stateModel.newDirectoryInput.isEmpty)
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // 操作按钮
            HStack(spacing: 12) {
                // 启用/暂停开关
                Toggle(isOn: Binding(
                    get: { stateModel.isEnabled },
                    set: { stateModel.toggleEnabled($0) }
                )) {
                    Text(String(localized: "relay.enabled", defaultValue: "启用"))
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .accessibilityHint(String(localized: "relay.accessibility.toggleHint", defaultValue: "Enable or pause mobile remote access"))

                Spacer()

                Button(String(localized: "relay.unpair", defaultValue: "解除配对"), role: .destructive) {
                    stateModel.showUnpairConfirm = true
                }
                .font(.caption)
                .accessibilityHint(String(localized: "relay.accessibility.unpairHint", defaultValue: "Unpair from phone, requires re-scanning QR code"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .alert(
            String(localized: "relay.unpair.confirm.title", defaultValue: "确认解除配对？"),
            isPresented: $stateModel.showUnpairConfirm
        ) {
            Button(String(localized: "relay.unpair.confirm.action", defaultValue: "解除配对"), role: .destructive) {
                stateModel.unpair()
            }
            Button(String(localized: "relay.unpair.confirm.cancel", defaultValue: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "relay.unpair.confirm.message", defaultValue: "解除后需要重新扫码才能连接"))
        }
    }

    // MARK: - 共用组件

    private func statusRow(_ text: String, color: Color) -> some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityLabel(String(localized: "relay.accessibility.statusIndicator", defaultValue: "Connection status: \(text)"))
            Text(text)
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var serverURLField: some View {
        HStack {
            Text(String(localized: "relay.server", defaultValue: "服务器"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("host:port", text: $stateModel.serverURLInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onSubmit { stateModel.saveServerURL() }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Relay 状态模型

enum RelayViewState {
    case unconfigured   // 没有服务器地址
    case unpaired       // 有服务器但没配对
    case pairing        // 正在显示二维码等待扫码
    case paired         // 已配对（可能连接或断开）
}

final class RelayStateModel: ObservableObject {
    @Published var viewState: RelayViewState = .unconfigured
    @Published var serverURLInput: String = ""
    @Published var isEnabled: Bool = false
    @Published var isConnected: Bool = false
    @Published var latencyMs: Int?
    @Published var pairedPhoneName: String?
    @Published var qrCodeImage: NSImage?
    @Published var pairingTimeRemaining: Int = 0
    @Published var error: String?
    @Published var showUnpairConfirm: Bool = false
    @Published var allowedDirectories: [String] = []
    @Published var newDirectoryInput: String = ""

    private var pairingTimer: Timer?
    private var pairingExpiresAt: Date?
    /// Issue 4: 保存配对确认轮询定时器，确保可清理
    private var pairingConfirmationTimer: Timer?
    /// 安全轮询凭据：pair/init 返回的 check_token，用于 pair/check 鉴权
    private var checkToken: String?
    /// Issue 3: 监听连接状态变化通知
    private var statusObserver: NSObjectProtocol?

    init() {
        refresh()
        // Issue 3: 订阅连接状态变化通知
        statusObserver = NotificationCenter.default.addObserver(
            forName: .relayConnectionStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let statusRaw = notification.userInfo?["status"] as? String {
                self.isConnected = (statusRaw == "connected")
            }
        }
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 默认中继服务器地址
    static let defaultServerURL = "devpod.rooyun.com"

    // 从 RelaySettings 刷新状态
    func refresh() {
        isEnabled = RelaySettings.isEnabled

        if RelaySettings.serverURL == nil {
            // 首次使用，自动保存默认地址，直接进入未配对状态
            serverURLInput = Self.defaultServerURL
            RelaySettings.serverURL = Self.defaultServerURL
            viewState = .unpaired
            return
        }

        serverURLInput = RelaySettings.serverURL ?? Self.defaultServerURL

        if serverURLInput.isEmpty {
            viewState = .unconfigured
        } else if RelaySettings.pairedPhoneID == nil {
            viewState = .unpaired
        } else {
            viewState = .paired
            pairedPhoneName = RelaySettings.pairedPhoneName
        }

        // 从 RelayBootstrap 获取连接状态
        if let client = RelayBootstrap.shared.client {
            isConnected = client.status == .connected
        }

        allowedDirectories = RelaySettings.allowedDirectories
    }

    var connectionStatusText: String {
        if !isEnabled {
            return String(localized: "relay.status.paused", defaultValue: "已暂停")
        }
        switch RelayBootstrap.shared.client?.status {
        case .connected:
            return String(localized: "relay.status.connected", defaultValue: "已连接")
        case .connecting:
            return String(localized: "relay.status.connecting", defaultValue: "连接中...")
        default:
            return String(localized: "relay.status.disconnected", defaultValue: "未连接")
        }
    }

    var connectionStatusColor: Color {
        if !isEnabled { return .gray }
        switch RelayBootstrap.shared.client?.status {
        case .connected: return .green
        case .connecting: return .yellow
        default:
            if RelaySettings.pairedPhoneID != nil { return .orange }
            return .gray
        }
    }

    // MARK: - 目录管理

    func addDirectory() {
        let dir = newDirectoryInput.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty, !allowedDirectories.contains(dir) else { return }
        allowedDirectories.append(dir)
        RelaySettings.allowedDirectories = allowedDirectories
        newDirectoryInput = ""
        // 注意：目录变更需要重连才对新沙箱生效
    }

    func removeDirectory(_ dir: String) {
        allowedDirectories.removeAll { $0 == dir }
        RelaySettings.allowedDirectories = allowedDirectories
    }

    // MARK: - 操作

    func saveServerURL() {
        let trimmed = serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        RelaySettings.serverURL = trimmed
        RelaySettings.isEnabled = true
        isEnabled = true

        if RelaySettings.pairedPhoneID != nil {
            viewState = .paired
            // 先保存 socketPath，再 stop，再用保存的值 start
            let socketPath = RelayBootstrap.shared.bridge?.socketPath ?? RelayBootstrap.shared.lastSocketPath
            RelayBootstrap.shared.stop()
            if let socketPath {
                RelayBootstrap.shared.start(socketPath: socketPath)
            }
        } else {
            viewState = .unpaired
        }
    }

    func toggleEnabled(_ enabled: Bool) {
        RelaySettings.isEnabled = enabled
        isEnabled = enabled
        if enabled {
            // 优先使用当前 bridge 的 socketPath，其次回退到上次保存的值
            let socketPath = RelayBootstrap.shared.bridge?.socketPath ?? RelayBootstrap.shared.lastSocketPath
            if let socketPath {
                RelayBootstrap.shared.start(socketPath: socketPath)
            } else {
                error = String(localized: "relay.error.noSocketPath", defaultValue: "Cannot re-enable: local socket path not found. Please restart the app.")
                RelaySettings.isEnabled = false
                isEnabled = false
            }
        } else {
            RelayBootstrap.shared.stop()
        }
    }

    func generateQRCode() {
        guard let serverURL = RelaySettings.serverURL, !serverURL.isEmpty else {
            error = "服务器地址未配置"
            print("[relay] generateQRCode: serverURL 为空")
            return
        }
        print("[relay] generateQRCode: serverURL=\(serverURL)")

        viewState = .pairing
        error = nil

        // 向 relay 服务器请求 pair_token
        let scheme = serverURL.hasPrefix("localhost") || serverURL.hasPrefix("127.0.0.1") ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(serverURL)/api/pair/init") else {
            // Issue 6: 本地化错误消息
            error = String(localized: "relay.error.invalidURL", defaultValue: "服务器地址无效")
            viewState = .unpaired
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "device_id": RelaySettings.deviceID,
            "device_name": RelaySettings.deviceName,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, err in
            DispatchQueue.main.async {
                guard let self else { return }

                if let err {
                    print("[relay] generateQRCode 网络错误: \(err)")
                    self.error = "网络错误: \(err.localizedDescription)"
                    self.viewState = .unpaired
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    print("[relay] generateQRCode HTTP status=\(httpResponse.statusCode)")
                    if httpResponse.statusCode != 200 {
                        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "无响应"
                        self.error = "服务器返回 \(httpResponse.statusCode): \(body)"
                        self.viewState = .unpaired
                        return
                    }
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pairToken = json["pair_token"] as? String,
                      let checkToken = json["check_token"] as? String
                else {
                    // Issue 6: 本地化错误消息
                    self.error = String(localized: "relay.error.serverError", defaultValue: "服务器响应错误")
                    self.viewState = .unpaired
                    return
                }

                // 保存 check_token 用于后续轮询鉴权
                self.checkToken = checkToken

                // 生成二维码
                let qrData: [String: String] = [
                    "server_url": serverURL,
                    "device_id": RelaySettings.deviceID,
                    "pair_token": pairToken,
                ]
                if let qrJSON = try? JSONSerialization.data(withJSONObject: qrData),
                   let qrString = String(data: qrJSON, encoding: .utf8) {
                    self.qrCodeImage = self.generateQRImage(from: qrString)
                }

                // 启动 5 分钟倒计时
                self.pairingTimeRemaining = 300
                self.pairingExpiresAt = Date().addingTimeInterval(300)
                self.pairingTimer?.invalidate()
                self.pairingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                    guard let self else { timer.invalidate(); return }
                    let remaining = Int(max(0, (self.pairingExpiresAt ?? Date()).timeIntervalSinceNow))
                    self.pairingTimeRemaining = remaining
                    if remaining <= 0 {
                        timer.invalidate()
                        // Issue 7: 倒计时结束后自动重新生成二维码
                        self.generateQRCode()
                    }
                }

                // Issue 1: 通过 HTTP 轮询服务器检查配对状态
                self.listenForPairingConfirmation(serverURL: serverURL)
            }
        }.resume()
    }

    func cancelPairing() {
        pairingTimer?.invalidate()
        pairingTimer = nil
        // Issue 4: 清理配对确认轮询定时器
        pairingConfirmationTimer?.invalidate()
        pairingConfirmationTimer = nil
        qrCodeImage = nil
        viewState = .unpaired
    }

    func unpair() {
        guard let phoneID = RelaySettings.pairedPhoneID else { return }

        // 通知 relay 服务器删除配对（服务器会通知手机端）
        if let serverURL = RelaySettings.serverURL, !serverURL.isEmpty {
            let scheme = serverURL.hasPrefix("localhost") || serverURL.hasPrefix("127.0.0.1") ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(serverURL)/api/pair/\(phoneID)") {
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                URLSession.shared.dataTask(with: request).resume()
            }
        }

        // 停止连接
        RelayBootstrap.shared.stop()

        // 清除本地配对信息
        RelaySettings.deletePairSecret(forPhone: phoneID)
        RelaySettings.pairedPhoneID = nil
        RelaySettings.pairedPhoneName = nil

        pairedPhoneName = nil
        isConnected = false
        viewState = .unpaired
    }

    // MARK: - 私有方法

    private func generateQRImage(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // 放大到合适尺寸
        let scale = 8.0
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: transformed.extent.width, height: transformed.extent.height))
    }

    /// Issue 1: 通过 HTTP 轮询 /api/pair/check/{device_id} 检查配对是否已完成
    private func listenForPairingConfirmation(serverURL: String) {
        // 清理上一次的定时器
        pairingConfirmationTimer?.invalidate()

        let scheme = serverURL.hasPrefix("localhost") || serverURL.hasPrefix("127.0.0.1") ? "http" : "https"
        let deviceID = RelaySettings.deviceID
        // 安全鉴权：带上 check_token 参数
        guard let token = checkToken,
              let checkURL = URL(string: "\(scheme)://\(serverURL)/api/pair/check/\(deviceID)?check_token=\(token)") else {
            return
        }

        pairingConfirmationTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.viewState != .pairing {
                timer.invalidate()
                self.pairingConfirmationTimer = nil
                return
            }

            var request = URLRequest(url: checkURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 5

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self, error == nil,
                      let data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = json["status"] as? String, status == "paired",
                      let pairSecret = json["pair_secret"] as? String,
                      let phoneID = json["phone_id"] as? String
                else {
                    return
                }

                let phoneName = (json["phone_name"] as? String) ?? ""

                // 保存配对信息
                do {
                    try RelaySettings.savePairSecret(pairSecret, forPhone: phoneID)
                    print("[relay] pair_secret 保存成功 phone=\(phoneID.prefix(10))")
                } catch {
                    print("[relay] pair_secret 保存失败: \(error)")
                }
                RelaySettings.pairedPhoneID = phoneID
                RelaySettings.pairedPhoneName = phoneName

                DispatchQueue.main.async {
                    timer.invalidate()
                    self.pairingConfirmationTimer = nil
                    self.pairingTimer?.invalidate()
                    self.pairingTimer = nil
                    self.qrCodeImage = nil
                    self.pairedPhoneName = phoneName

                    // Issue 9: 配对成功带过渡动画
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.viewState = .paired
                    }

                    // 配对成功后自动启用并连接
                    RelaySettings.isEnabled = true
                    self.isEnabled = true
                    let socketPath = RelayBootstrap.shared.bridge?.socketPath
                        ?? SocketControlSettings.socketPath()
                    RelayBootstrap.shared.start(socketPath: socketPath)
                }
            }.resume()
        }
    }
}
