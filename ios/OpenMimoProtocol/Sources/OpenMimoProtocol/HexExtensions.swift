import Foundation

/// 十六进制编解码工具：协议调试日志、MAC/凭据解析共用。
/// 此前散落在 ConnectionFlow / StepLogger / CameraBleWake / OSMOCameraLink 等 ≥10 处内联。
public extension Sequence where Element == UInt8 {
    /// 小写 hex 串（无分隔符）：`[0xDE, 0xAD]` → "dead"。
    /// Data / ArraySlice<UInt8> 等同为 UInt8 序列，直接适用。
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

public extension String {
    /// hex 串 → 字节。两位一组解析，非法字符跳过；结果为空返回 nil。
    /// 与 ConnectionFlow 原 hexToBytes 行为一致（MAC 缓存等场景依赖此语义）。
    func hexToBytes() -> [UInt8]? {
        var bytes: [UInt8] = []
        var idx = startIndex
        while idx < endIndex {
            let next = index(idx, offsetBy: 2, limitedBy: endIndex) ?? endIndex
            if let b = UInt8(self[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        return bytes.isEmpty ? nil : bytes
    }
}
