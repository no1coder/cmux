import Foundation

// MARK: - FileEntry

/// 目录条目信息
struct FileEntry {
    /// 文件或目录名称
    let name: String
    /// 类型："file" 或 "directory"
    let type: String
    /// 文件大小（字节），目录为 0
    let size: Int64
    /// 最后修改时间（Unix 毫秒时间戳）
    let modified: Int64

    /// 转换为字典，便于 JSON 序列化
    func toDictionary() -> [String: Any] {
        return [
            "name": name,
            "type": type,
            "size": size,
            "modified": modified,
        ]
    }
}

// MARK: - RelayFileHandler

/// 文件操作处理器：列目录、读取文件内容
struct RelayFileHandler {

    // MARK: - 属性

    /// 路径沙箱，用于验证访问权限
    let sandbox: RelayFileSandbox

    /// 单次读取文件最大字节数（10MB）
    private static let maxFileSize: Int64 = 10 * 1024 * 1024

    /// 图片扩展名集合
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp",
    ]

    // MARK: - 公开接口

    /// 列出目录内容
    /// - Parameter path: 目录路径
    /// - Returns: 包含 entries 数组的字典
    /// - Throws: `FileSandboxError` 或文件系统错误
    func listDirectory(path: String) throws -> [String: Any] {
        // 展开 ~ 为用户 home 目录
        let expandedPath = (path as NSString).expandingTildeInPath
        let validatedPath = try sandbox.validate(path: expandedPath)

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: validatedPath, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadUnknown)
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: validatedPath)

        // 过滤隐藏文件，但保留 .gitignore 等常用配置文件
        let allowedHiddenFiles: Set<String> = [
            ".gitignore", ".gitattributes", ".editorconfig", ".prettierrc",
            ".eslintrc", ".eslintignore", ".babelrc", ".nvmrc", ".node-version",
        ]

        let filtered = contents.filter { name in
            // 跳过以 "." 开头的隐藏文件，但保留白名单内的
            if name.hasPrefix(".") {
                return allowedHiddenFiles.contains(name)
            }
            return true
        }

        var entries: [[String: Any]] = []
        for name in filtered.sorted() {
            let fullPath = (validatedPath as NSString).appendingPathComponent(name)
            var entryIsDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &entryIsDir)

            let attributes = (try? FileManager.default.attributesOfItem(atPath: fullPath)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modDate = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let modifiedMs = Int64(modDate.timeIntervalSince1970 * 1000)

            let entry = FileEntry(
                name: name,
                type: entryIsDir.boolValue ? "directory" : "file",
                size: entryIsDir.boolValue ? 0 : size,
                modified: modifiedMs
            )
            entries.append(entry.toDictionary())
        }

        return ["entries": entries]
    }

    /// 读取文件内容
    /// - Parameter path: 文件路径
    /// - Returns: 包含文件内容的字典；图片返回 base64，文本返回 utf8 字符串，二进制返回 base64
    /// - Throws: `FileSandboxError` 或文件系统错误
    func readFile(path: String) throws -> [String: Any] {
        let expandedPath = (path as NSString).expandingTildeInPath
        let validatedPath = try sandbox.validate(path: expandedPath)

        // 检查文件大小限制
        let attributes = (try? FileManager.default.attributesOfItem(atPath: validatedPath)) ?? [:]
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= Self.maxFileSize else {
            throw CocoaError(.fileReadTooLarge)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: validatedPath))

        // 根据扩展名判断是否为图片
        let ext = (validatedPath as NSString).pathExtension.lowercased()
        let mime = mimeType(for: ext)

        if Self.imageExtensions.contains(ext) {
            // 图片：返回 base64 编码
            return [
                "encoding": "base64",
                "mimeType": mime,
                "content": data.base64EncodedString(),
                "size": fileSize,
            ]
        }

        // 文本文件：尝试 UTF-8 解码
        if let text = String(data: data, encoding: .utf8) {
            return [
                "encoding": "utf8",
                "mimeType": mime,
                "content": text,
                "size": fileSize,
            ]
        }

        // 二进制文件 fallback：返回 base64
        return [
            "encoding": "base64",
            "mimeType": mime,
            "content": data.base64EncodedString(),
            "size": fileSize,
        ]
    }

    // MARK: - 辅助方法

    /// 根据文件扩展名返回 MIME 类型
    /// - Parameter ext: 文件扩展名（小写）
    /// - Returns: MIME 类型字符串
    func mimeType(for ext: String) -> String {
        switch ext {
        // 图片
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        // 文本
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "csv": return "text/csv"
        // 代码
        case "js", "mjs": return "application/javascript"
        case "ts": return "application/typescript"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/yaml"
        case "sh", "zsh", "bash": return "application/x-sh"
        case "swift": return "text/x-swift"
        case "py": return "text/x-python"
        case "rb": return "text/x-ruby"
        case "go": return "text/x-go"
        case "rs": return "text/x-rust"
        case "java": return "text/x-java"
        case "c", "h": return "text/x-c"
        case "cpp", "hpp", "cc": return "text/x-c++"
        // 视频
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "m4v": return "video/x-m4v"
        case "flv": return "video/x-flv"
        case "wmv": return "video/x-ms-wmv"
        // 音频
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        // 二进制
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        default: return "application/octet-stream"
        }
    }
}
