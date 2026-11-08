import Foundation
import CryptoKit
import CommonCrypto

/// BLE WiFi 凭据交换协议的加密层（docs/protocol/ble-provisioning.md）。
///
/// 流程：P-256 ECDH → HKDF-SHA256(info="BLE-WiFi-v1") → AES-128-CBC 解密凭据。
public enum WiFiCredentialCrypto {

    /// HKDF info 常量（协议版本标识，从反汇编 rodata 提取）
    public static let hkdfInfo = Data("BLE-WiFi-v1".utf8)

    // MARK: - ECDH P-256

    /// 生成 P-256 密钥对。
    /// - Returns: `(公钥未压缩 65B [0x04‖X‖Y], 私钥原始 32B)` 或 nil
    public static func generateECDHKeyPair() -> (publicKey: Data, privateKey: Data)? {
        let priv = P256.KeyAgreement.PrivateKey()
        guard let pubData = try? priv.publicKey.x963Representation else { return nil }
        return (pubData, priv.rawRepresentation)
    }

    /// 从对端公钥（未压缩 65B）+ 本端私钥计算 ECDH 共享密钥（32B）。
    public static func computeSharedSecret(peerPublicKey: Data, privateKey: Data) -> Data? {
        guard let priv = try? P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey),
              let secret = try? priv.sharedSecretFromKeyAgreement(with: peer)
        else { return nil }
        return secret.withUnsafeBytes { Data($0) }
    }

    // MARK: - HKDF-SHA256

    /// HKDF-SHA256 derive，输出 32 字节 → AES-128 key(16B) ‖ IV(16B)。
    public static func hkdfSha256(ikm: Data, salt: Data, info: Data = hkdfInfo) -> Data {
        let ikmKey = SymmetricKey(data: ikm)
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikmKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return okm.withUnsafeBytes { Data($0) }
    }

    /// 从 32B HKDF 输出拆分 AES key + IV。
    public static func splitSessionKeyMaterial(_ okm: Data) -> (aesKey: Data, iv: Data)? {
        guard okm.count >= 32 else { return nil }
        return (okm.prefix(16), okm.suffix(16))
    }

    // MARK: - AES-128-CBC 解密

    /// AES-128-CBC 解密（PKCS7 去填充可选；密文长度须为 16 的倍数）。
    public static func aes128CbcDecrypt(key: Data, iv: Data, ciphertext: Data,
                                        removePKCS7Padding: Bool = false) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128,
              !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0
        else { return nil }

        var outBuf = Data(repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outLen = 0
        let outBufCount = outBuf.count
        let status = outBuf.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { ctPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(removePKCS7Padding ? kCCOptionPKCS7Padding : 0),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            ctPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outBufCount,
                            &outLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        outBuf.removeSubrange(outLen..<outBuf.count)
        return outBuf
    }

    // MARK: - 高层：凭据解密

    /// 用缓存的会话密钥解密 wifi_get_ssid / wifi_get_password 的加密应答。
    public static func decryptCredentialResponse(sessionAESKey: Data, sessionIV: Data,
                                                 encrypted: Data) -> Data? {
        aes128CbcDecrypt(key: sessionAESKey, iv: sessionIV, ciphertext: encrypted)
    }
}
