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

    /// 敏感文件/目录匹配模式（小写匹配）
    private static let sensitivePatterns: [String] = [
        ".env",
        ".ssh/",
        ".gnupg/",
        ".aws/",
        "credentials",
        "secrets",
        "id_rsa",
        "id_ed25519",
        ".npmrc",
        ".pypirc",
    ]

    // MARK: - 公开接口

    /// 验证路径是否安全可访问，返回标准化后的路径
    /// - Parameter path: 待验证的文件路径
    /// - Returns: 标准化后的路径字符串
    /// - Throws: `FileSandboxError` 如果路径不安全
    func validate(path: String) throws -> String {
        // 1. 拒绝包含 ".." 的路径（防止路径穿越）
        if path.contains("..") {
            throw FileSandboxError.pathTraversal
        }

        // 2. 标准化 URL（消除多余斜杠等）
        let fileURL = URL(fileURLWithPath: path).standardized
        let standardizedPath = fileURL.path

        // 3. 检查文件是否存在
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            throw FileSandboxError.fileNotFound
        }

        // 4. 解析符号链接，验证目标在允许的根目录内
        let resolvedPath: String
        do {
            resolvedPath = try FileManager.default.destinationOfSymbolicLink(atPath: standardizedPath)
        } catch {
            // 不是符号链接，使用标准化路径本身
            let resolved = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath().path
            resolvedPath = resolved
        }

        // 检查解析后的路径是否在允许根目录下
        if !isUnderAllowedRoot(resolvedPath) {
            throw FileSandboxError.symbolicLinkEscape
        }

        // 5. 检查标准化路径是否在允许的根目录下
        if !isUnderAllowedRoot(standardizedPath) {
            throw FileSandboxError.pathOutsideAllowedRoot
        }

        // 6. 检查敏感文件模式
        let lowerPath = standardizedPath.lowercased()
        for pattern in Self.sensitivePatterns {
            if lowerPath.contains(pattern) {
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
