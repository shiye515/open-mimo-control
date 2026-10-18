import Foundation
import CryptoKit
import CommonCrypto

/// BLE 通道 WiFi 凭据交换（认证+唤醒后走 ECDH 交换获取真实 SSID+密码）。
///
/// 协议流程（docs/protocol/ble-provisioning.md）：
/// 1. 发送 ECDH 交换命令 → payload=本端公钥(65B)+rand_app
/// 2. 解析应答 → 相机公钥 + rand_dev
/// 3. ComputeSharedSecret → HKDF-SHA256(info="BLE-WiFi-v1") → AES-128 key(16B) + IV(16B)
/// 4. 发送 wifi_get_ssid + wifi_get_password 命令
/// 5. 解密应答 → 明文 SSID + password
///
/// 注意：payload 的字节级布局基于反汇编推断，需真机校准。
/// 命令编址 (CmdSet=0x02, CmdID=0x92/0x07/0x0E) 从 WiFi 通道反汇编推定。
public enum BLECredentialExchange {

    // MARK: - 命令构造（DUML 0x55 帧格式，BLE 认证后通道）

    /// ECDH 交换命令（native 三元组 (1, 0x12, 0x92)，日志 "APP->WMS 0x1292 Req(type=0x00 ECDH)"）：
    /// CmdSet=0x12, CmdId=0x92。payload 布局真机校准中（见 CameraBleWaker 变体轮换）。
    public static func buildECDHExchangeRaw(payload: [UInt8], sequence: UInt16) -> [UInt8] {
        return DjiRProtocol.buildFrame(cmdType: 0x01, cmdSet: 0x12, cmdId: 0x92,
                                       payload: payload, sequence: sequence)
    }

    /// wifi_get_ssid（native (1, 0x07, 0x07)）：CmdSet=0x07, CmdId=0x07
    public static func buildGetSSID(sequence: UInt16) -> [UInt8] {
        return DjiRProtocol.buildFrame(cmdType: 0x01, cmdSet: 0x07, cmdId: 0x07,
                                       payload: [], sequence: sequence)
    }

    /// wifi_get_password（native (1, 0x07, 0x0E)）：CmdSet=0x07, CmdId=0x0E
    public static func buildGetPassword(sequence: UInt16) -> [UInt8] {
        return DjiRProtocol.buildFrame(cmdType: 0x01, cmdSet: 0x07, cmdId: 0x0E,
                                       payload: [], sequence: sequence)
    }

    // MARK: - 密钥派生

    /// HKDF-SHA256 派生会话密钥。
    /// - Parameters:
    ///   - sharedSecret: ECDH 共享密钥（32B）
    ///   - randDev: 相机侧随机数（从 ECDH 应答提取）
    ///   - randApp: App 侧随机数（发送 ECDH 交换时生成）
    /// - Returns: `(aesKey 16B, iv 16B)` 或 nil
    public static func deriveSessionKey(sharedSecret: Data,
                                        randDev: Data, randApp: Data) -> (aesKey: Data, iv: Data)? {
        let ikm = sharedSecret + randDev + randApp
        let salt = randDev
        let okm = WiFiCredentialCrypto.hkdfSha256(ikm: ikm, salt: salt,
                                                  info: WiFiCredentialCrypto.hkdfInfo)
        guard okm.count >= 32 else { return nil }
        return (okm.prefix(16), okm.suffix(16))
    }

    // MARK: - 凭据解密

    /// AES-128-CBC 解密 wifi_get_ssid / wifi_get_password 的加密应答。
    public static func decryptCredential(aesKey: Data, iv: Data, encrypted: Data) -> Data? {
        return WiFiCredentialCrypto.aes128CbcDecrypt(key: aesKey, iv: iv, ciphertext: encrypted)
    }
}
