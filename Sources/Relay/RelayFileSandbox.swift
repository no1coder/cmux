import Foundation

// MARK: - FileSandboxError

/// 文件沙箱访问错误
enum FileSandboxError: Error {
    /// 路径不在允许的根目录下
    case pathOutsideAllowedRoot
    /// 路径包含路径穿越（如 ".."）
    case pathTraversal
    /// 符号链接目标超出允许的根目录
    case symbolicLinkEscape
    /// 敏感文件，拒绝访问
    case sensitiveFile
    /// 文件不存在
    case fileNotFound
}

// MARK: - RelayFileSandbox

/// 强制路径沙箱：验证路径是否安全，防止目录穿越和敏感文件访问
struct RelayFileSandbox {

    // MARK: - 属性

    /// 允许访问的根目录列表
    let allowedRoots: [String]

    /// 敏感文件/目录名称精确匹配（路径组件或文件名完全相等，小写）
    private static let sensitiveNames: [String] = [
        ".env",
        ".ssh",
        ".gnupg",
        ".aws",
        "credentials",
        "secrets",
        "id_rsa",
        "id_ed25519",
        ".npmrc",
        ".pypirc",
        // 扩充：容器凭证、SSH 已知主机
        ".netrc",
        "known_hosts",
    ]

    /// 敏感文件扩展名精确匹配（文件扩展名完全相等，小写，不含点）
    private static let sensitiveExtensions: [String] = [
        "pem",
        "key",
        "p12",
    ]

    /// 需要结合父目录判断的敏感路径（父目录名 → 文件名，均小写）
    private static let sensitiveContextPaths: [(parent: String, filename: String)] = [
        (".docker", "config.json"),
        (".kube", "config"),
    ]

    // MARK: - 公开接口

    /// 验证路径是否安全可访问，返回标准化后的路径
    /// - Parameter path: 待验证的文件路径
    /// - Returns: 标准化后的路径字符串
    /// - Throws: `FileSandboxError` 如果路径不安全
    func validate(path: String) throws -> String {
        // 1. 拒绝路径组件中含有 ".." 的路径（防止路径穿越）
        //    使用 pathComponents 精确匹配，避免误判含 ".." 的合法文件名
        let components = (path as NSString).pathComponents
        if components.contains("..") {
            throw FileSandboxError.pathTraversal
        }

        // 2. 标准化 URL（消除多余斜杠等）
        let fileURL = URL(fileURLWithPath: path).standardized
        let standardizedPath = fileURL.path

        // 3. 先检查路径是否在允许根目录下（防止路径预言机攻击：通过文件存在性探测路径）
        if !isUnderAllowedRoot(standardizedPath) {
            throw FileSandboxError.pathOutsideAllowedRoot
        }

        // 4. 先解析符号链接，再检查存在性（消除 TOCTOU 竞态：先 exists 再 resolve 的间隙可被利用）
        let resolvedPath = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath().path

        // 5. 检查解析后的文件是否存在
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw FileSandboxError.fileNotFound
        }

        // 6. 检查解析后的路径是否在允许根目录下（防止符号链接逃逸）
        if !isUnderAllowedRoot(resolvedPath) {
            throw FileSandboxError.symbolicLinkEscape
        }

        // 7. 检查敏感文件模式（精确匹配路径组件，避免误判含敏感词的无害文件名）
        let nsPath = standardizedPath as NSString
        let lowerComponents = nsPath.pathComponents.map { $0.lowercased() }
        let lowerFilename = nsPath.lastPathComponent.lowercased()
        let lowerExtension = (lowerFilename as NSString).pathExtension.lowercased()
        let lowerParent = (nsPath.deletingLastPathComponent as NSString)
            .lastPathComponent.lowercased()

        // 7a. 名称精确匹配（文件名或路径中任意组件）
        for name in Self.sensitiveNames {
            if lowerComponents.contains(name) {
                throw FileSandboxError.sensitiveFile
            }
        }

        // 7b. 扩展名匹配（*.pem / *.key / *.p12 等）
        if !lowerExtension.isEmpty, Self.sensitiveExtensions.contains(lowerExtension) {
            throw FileSandboxError.sensitiveFile
        }

        // 6c. 需要结合父目录的上下文匹配（如 .docker/config.json、.kube/config）
        for ctx in Self.sensitiveContextPaths {
            if lowerParent == ctx.parent && lowerFilename == ctx.filename {
                throw FileSandboxError.sensitiveFile
            }
        }

        return standardizedPath
    }

    /// 检查路径是否在允许的根目录下
    /// - Parameter path: 待检查的路径
    /// - Returns: 是否在允许的根目录下
    func isUnderAllowedRoot(_ path: String) -> Bool {
        for root in allowedRoots {
            let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(normalizedRoot) || path == root {
                return true
            }
        }
        return false
    }
}
