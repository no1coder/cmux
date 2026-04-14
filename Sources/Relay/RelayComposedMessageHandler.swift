import AppKit
import Bonsplit
import Foundation

/// 混合消息处理器：接收手机端的 composed_msg 事件，组装后按序注入终端
/// 协议：composed_msg.start → composed_msg.block × N → composed_msg.end
final class RelayComposedMessageHandler {

    /// 单条消息最大 block 数量上限
    private static let maxBlockCount = 50
    /// 单张图片最大数据量（10 MB）
    private static let maxImageDataSize = 10 * 1024 * 1024
    /// 同时允许的最大未完成消息数
    private static let maxPendingMessages = 20

    /// 串行队列保护 pendingMessages 读写
    private let queue = DispatchQueue(label: "com.cmux.relay.composedMsg")

    /// 正在组装中的消息
    private var pendingMessages: [String: PendingMessage] = [:]

    /// 注入依赖（weak 避免与 RelayBridge.composedMessageHandler 形成循环引用）
    private weak var bridge: RelayBridge?

    /// 临时图片目录（使用系统临时目录，兼容 tagged build 隔离）
    private let imageDir: String = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-images").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(bridge: RelayBridge) {
        self.bridge = bridge
    }

    // MARK: - 消息组装

    /// 处理 composed_msg RPC 请求
    /// - Returns: RPC 响应字典
    func handleRPC(method: String, params: [String: Any]?) -> [String: Any] {
        queue.sync {
            guard let params else {
                return ["error": "missing params"]
            }

            switch method {
            case "composed_msg.start":
                return handleStart(params)
            case "composed_msg.block":
                return handleBlock(params)
            case "composed_msg.end":
                return handleEnd(params)
            default:
                return ["error": "unknown composed_msg method: \(method)"]
            }
        }
    }

    private func handleStart(_ params: [String: Any]) -> [String: Any] {
        // 顺便清理超时消息
        cleanupStaleMessages()

        guard let msgID = params["msg_id"] as? String,
              let surfaceID = params["surface_id"] as? String,
              let blockCount = params["block_count"] as? Int else {
            return ["error": "invalid composed_msg.start params"]
        }

        // 校验 msgID 长度，防止恶意超长键占用内存
        guard msgID.count <= 64 else {
            return ["error": "msg_id too long (max 64 chars)"]
        }

        guard blockCount > 0, blockCount <= Self.maxBlockCount else {
            return ["error": "block_count out of range (1...\(Self.maxBlockCount))"]
        }

        // 限制同时进行的消息组装数，防止内存耗尽
        guard pendingMessages.count < Self.maxPendingMessages else {
            return ["error": "too many pending messages"]
        }

        guard RelayBridge.isValidID(surfaceID) else {
            return ["error": "invalid surface_id format"]
        }

        #if DEBUG
        dlog("[relay][compose] start: msgID=\(msgID) surfaceID=\(surfaceID) blocks=\(blockCount)")
        #endif

        let pending = PendingMessage(
            msgID: msgID,
            surfaceID: surfaceID,
            expectedBlockCount: blockCount
        )
        pendingMessages[msgID] = pending
        return ["ok": true]
    }

    private func handleBlock(_ params: [String: Any]) -> [String: Any] {
        guard let msgID = params["msg_id"] as? String,
              let index = params["index"] as? Int,
              let type = params["type"] as? String else {
            return ["error": "invalid composed_msg.block params"]
        }

        guard let pending = pendingMessages[msgID] else {
            return ["error": "unknown msg_id: \(msgID)"]
        }

        guard index >= 0, index < pending.expectedBlockCount else {
            return ["error": "block index out of range"]
        }
        guard !pending.blocks.contains(where: { $0.index == index }) else {
            return ["error": "duplicate block index"]
        }

        let block: ReceivedBlock
        switch type {
        case "text":
            let content = params["content"] as? String ?? ""
            block = .text(content)

        case "image":
            guard let base64 = params["data"] as? String,
                  let data = Data(base64Encoded: base64) else {
                return ["error": "invalid image data"]
            }
            guard data.count <= Self.maxImageDataSize else {
                return ["error": "image too large (max \(Self.maxImageDataSize / 1024 / 1024) MB)"]
            }
            let format = params["format"] as? String ?? "jpeg"
            block = .image(data, format: format)

        default:
            return ["error": "unknown block type: \(type)"]
        }

        // PendingMessage 是 class，引用语义，无需写回字典
        pending.blocks.append((index: index, block: block))

        #if DEBUG
        dlog("[relay][compose] block: msgID=\(msgID) index=\(index) type=\(type) received=\(pending.blocks.count)/\(pending.expectedBlockCount)")
        #endif

        return ["ok": true]
    }

    private func handleEnd(_ params: [String: Any]) -> [String: Any] {
        guard let msgID = params["msg_id"] as? String else {
            return ["error": "invalid composed_msg.end params"]
        }

        guard let pending = pendingMessages.removeValue(forKey: msgID) else {
            return ["error": "unknown msg_id: \(msgID)"]
        }

        #if DEBUG
        dlog("[relay][compose] end: msgID=\(msgID) blocks=\(pending.blocks.count)")
        #endif

        // 按 index 排序
        let sortedBlocks = pending.blocks.sorted { $0.index < $1.index }.map(\.block)

        // 注入到终端
        injectToTerminal(surfaceID: pending.surfaceID, blocks: sortedBlocks)

        return ["ok": true]
    }

    // MARK: - 终端注入

    /// 按顺序将混合内容注入到目标 surface
    private func injectToTerminal(surfaceID: String, blocks: [ReceivedBlock]) {
        guard let bridge else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var tempFilePaths: [String] = []

            for (i, block) in blocks.enumerated() {
                switch block {
                case .text(let content):
                    // 文字：通过 surface.send_text 键入
                    bridge.forwardToSocketDirect(
                        method: "surface.send_text",
                        params: ["surface_id": surfaceID, "text": content]
                    )

                case .image(let data, let format):
                    // 图片：写入临时文件 → 写入剪贴板 → 模拟 Cmd+V
                    let ext = format == "png" ? "png" : "jpg"
                    let filename = "\(UUID().uuidString).\(ext)"
                    let filePath = "\(self.imageDir)/\(filename)"

                    // 写入临时文件（备用）
                    try? data.write(to: URL(fileURLWithPath: filePath))
                    tempFilePaths.append(filePath)

                    // 写入系统剪贴板：使用 asyncAndWait 在 main queue 上同步执行
                    // 相比 semaphore + async 的组合，asyncAndWait 不会阻塞调用线程的
                    // 同时引发 main queue 排队死锁（macOS 13+）
                    DispatchQueue.main.asyncAndWait {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        // 同时提供 TIFF 和 PNG 格式，确保 Claude Code 能识别
                        if let image = NSImage(data: data) {
                            pasteboard.writeObjects([image])
                        }
                    }

                    // 模拟 Cmd+V 粘贴图片（macOS 粘贴快捷键）
                    bridge.forwardToSocketDirect(
                        method: "surface.send_key",
                        params: ["surface_id": surfaceID, "key": "cmd-v"]
                    )
                }

                // 块间等待，确保终端处理完上一步（非关键路径，usleep 比 Thread.sleep 更轻量）
                if i < blocks.count - 1 {
                    usleep(150_000)
                }
            }

            // 最后等待一下再按回车提交
            usleep(100_000)
            bridge.forwardToSocketDirect(
                method: "surface.send_key",
                params: ["surface_id": surfaceID, "key": "enter"]
            )

            // 清理临时图片文件
            for path in tempFilePaths {
                try? FileManager.default.removeItem(atPath: path)
            }

            #if DEBUG
            DispatchQueue.main.async {
                dlog("[relay][compose] 注入完成: surfaceID=\(surfaceID) blocks=\(blocks.count) tempFiles=\(tempFilePaths.count)")
            }
            #endif
        }
    }

    // MARK: - 清理

    /// 清理超时的未完成消息（可定期调用）
    func cleanupStaleMessages(olderThan seconds: TimeInterval = 60) {
        let cutoff = Date().addingTimeInterval(-seconds)
        pendingMessages = pendingMessages.filter { $0.value.createdAt > cutoff }
    }
}

// MARK: - 内部数据结构

/// 使用引用语义，避免 struct 副本 mutation 漏写回的坑
private final class PendingMessage {
    let msgID: String
    let surfaceID: String
    let expectedBlockCount: Int
    var blocks: [(index: Int, block: ReceivedBlock)] = []
    let createdAt = Date()

    init(msgID: String, surfaceID: String, expectedBlockCount: Int) {
        self.msgID = msgID
        self.surfaceID = surfaceID
        self.expectedBlockCount = expectedBlockCount
    }
}

enum ReceivedBlock {
    case text(String)
    case image(Data, format: String)
}
