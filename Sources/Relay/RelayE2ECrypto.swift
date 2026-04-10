import Bonsplit
import CryptoKit
import Foundation

/// E2E 加密管理器：从 pairSecret 派生密钥，加解密 relay 消息
/// 使用 HKDF-SHA256 派生密钥，ChaChaPoly 加解密
/// Relay Server 保持零知识：只能路由 envelope 元数据，无法读取 payload
final class RelayE2ECrypto {
    private let symmetricKey: SymmetricKey

    init(pairSecret: String) {
        // HKDF-SHA256 派生 256-bit 对称密钥
        let ikm = SymmetricKey(data: Data(pairSecret.utf8))
        let salt = Data("cmux-e2e-v1".utf8)
        let info = Data("encryption".utf8)
        self.symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// 加密 payload 字典，返回包含 e2e/v/nonce/ct 的加密 payload
    func encrypt(_ payload: [String: Any]) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return nil
        }
        guard let sealed = try? ChaChaPoly.seal(data, using: symmetricKey) else {
            return nil
        }
        let nonceBase64 = sealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString()
        let ctBase64 = sealed.ciphertext.withUnsafeBytes { Data($0) }.base64EncodedString()
        let tagBase64 = sealed.tag.withUnsafeBytes { Data($0) }.base64EncodedString()
        return [
            "e2e": true,
            "v": 1,
            "nonce": nonceBase64,
            "ct": ctBase64 + ":" + tagBase64,
        ]
    }

    /// 解密 e2e payload，返回原始 payload 字典
    func decrypt(_ e2ePayload: [String: Any]) -> [String: Any]? {
        // 校验加密版本号，防止未来版本不兼容时静默解密错误数据
        guard let version = e2ePayload["v"] as? Int else {
            #if DEBUG
            dlog("[relay][crypto] 解密失败：缺少版本号字段")
            #endif
            return nil
        }
        guard version == 1 else {
            #if DEBUG
            dlog("[relay][crypto] 不支持的加密版本 v=\(version)，当前仅支持 v=1")
            #endif
            return nil
        }

        guard let nonceB64 = e2ePayload["nonce"] as? String,
              let ctAndTag = e2ePayload["ct"] as? String,
              let nonceData = Data(base64Encoded: nonceB64)
        else {
            return nil
        }

        let parts = ctAndTag.split(separator: ":")
        guard parts.count == 2,
              let ct = Data(base64Encoded: String(parts[0])),
              let tag = Data(base64Encoded: String(parts[1]))
        else {
            return nil
        }

        guard let nonce = try? ChaChaPoly.Nonce(data: nonceData),
              let sealedBox = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let decrypted = try? ChaChaPoly.open(sealedBox, using: symmetricKey),
              let json = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any]
        else {
            return nil
        }

        return json
    }

    /// 检查 payload 是否为 e2e 加密格式
    static func isEncrypted(_ payload: [String: Any]) -> Bool {
        (payload["e2e"] as? Bool) == true
    }
}
