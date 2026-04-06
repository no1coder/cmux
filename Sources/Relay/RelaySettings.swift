import Darwin
import Foundation
#if canImport(Security)
import Security
#endif

/// 中继功能的配置管理，通过文件持久化普通设置，Keychain 存储密钥
struct RelaySettings {

    // MARK: - 存储目录

    /// 配置文件目录：~/Library/Application Support/cmux/relay/
    static let settingsDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("cmux/relay", isDirectory: true)
    }()

    // MARK: - 普通设置（文件持久化）

    /// 中继服务器地址（如 "wss://relay.example.com"）
    static var serverURL: String? {
        get { readFile("server-url") }
        set { writeFile("server-url", content: newValue) }
    }

    /// 设备 ID，首次访问时自动生成并持久化
    static var deviceID: String {
        if let existing = readFile("device-id") { return existing }
        let id = "mac-" + UUID().uuidString.prefix(8).lowercased()
        writeFile("device-id", content: id)
        return id
    }

    /// 设备显示名称
    static var deviceName: String {
        get { readFile("device-name") ?? Host.current().localizedName ?? "Mac" }
        set { writeFile("device-name", content: newValue) }
    }

    /// 远程访问总开关
    static var isEnabled: Bool {
        get { readFile("enabled") == "true" }
        set { writeFile("enabled", content: newValue ? "true" : "false") }
    }

    /// 已配对手机的 ID
    static var pairedPhoneID: String? {
        get { readFile("paired-phone-id") }
        set { writeFile("paired-phone-id", content: newValue) }
    }

    // MARK: - Keychain（pair_secret）

    private static let keychainService = "com.cmux.relay.pair-secret"

    /// 将配对密钥保存到 Keychain
    static func savePairSecret(_ secret: String, forPhone phoneID: String) throws {
#if canImport(Security)
        // 先删除旧条目，避免重复
        deletePairSecret(forPhone: phoneID)

        guard let data = secret.data(using: .utf8) else {
            throw RelaySettingsError.invalidSecret
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: phoneID,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw RelaySettingsError.keychainError(status)
        }
#else
        throw RelaySettingsError.keychainUnavailable
#endif
    }

    /// 从 Keychain 读取配对密钥
    static func loadPairSecret(forPhone phoneID: String) -> String? {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: phoneID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
#else
        return nil
#endif
    }

    /// 删除 Keychain 中的配对密钥
    static func deletePairSecret(forPhone phoneID: String) {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: phoneID,
        ]
        SecItemDelete(query as CFDictionary)
#endif
    }

    // MARK: - 文件 I/O 辅助方法

    /// 读取配置文件内容，失败返回 nil
    private static func readFile(_ name: String) -> String? {
        let url = settingsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 写入配置文件；content 为 nil 时删除文件
    private static func writeFile(_ name: String, content: String?) {
        let url = settingsDir.appendingPathComponent(name)

        // 确保目录存在
        do {
            try FileManager.default.createDirectory(
                at: settingsDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return
        }

        guard let content else {
            // content 为 nil 时删除文件
            try? FileManager.default.removeItem(at: url)
            return
        }

        let data = Data((content + "\n").utf8)
        do {
            try data.write(to: url, options: .atomic)
            // 文件权限设为 0o600（仅所有者可读写）
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // 写入失败静默忽略，调用方可通过读取验证
        }
    }
}

// MARK: - 错误类型

enum RelaySettingsError: Error {
    case invalidSecret
    case keychainUnavailable
    case keychainError(OSStatus)
}
