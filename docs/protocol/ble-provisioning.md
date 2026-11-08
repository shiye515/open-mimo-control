# BLE WiFi 凭据下发协议（ble-provisioning）

> 状态：**关键假设已被真机实测推翻**（2026-10-28 修正）。本文 §3/§4 的 ECDH+加密假设
> 来自 native 反汇编，但 **BLE 阶段实测不需要**：Mimo 连上 FFF5 后直接发明文 DUML 帧序，
> get_ssid/get_password 应答均为明文 `[ret:1][len:1][UTF-8]`（9 种 ECDH 变体 0x92 帧无应答）。
> 已验证的稳定实现见 [connection-implementation.md](connection-implementation.md)；
> 本文的加密栈分析仅适用于 WiFi 侧 `(07,72)` 加密入口，保留作协议事实与后续参考。

## 1. 机制概述

相机的 WiFi 热点凭据（SSID/密码）**不会明文暴露**：App 需通过 BLE 先完成 ECDH 密钥交换，
随后用会话密钥解密 `wifi_get_ssid` / `wifi_get_password` 命令的加密应答。
这解释了为何系统设置里"输入相机屏幕显示的密码"无法连接——**真实凭据按会话轮换，仅通过加密 BLE 通道下发**。

## 2. WiFi 模块命令表（已证实，CmdSet=1 / 模块=7）

| (CmdSet, 模块, CmdID) | 命令 |
| --- | --- |
| (1, 7, 7) | wifi_get_ssid |
| (1, 7, 10) | wifi_get_rssi |
| (1, 7, 12) | wifi_get_mac |
| (1, 7, 13) | wifi_set_password |
| (1, 7, 14) | **wifi_get_password** |
| (1, 7, 16) | wifi_set_frequency_switch |
| (1, 7, 171/172) | 扫描列表查询/推送 |

## 3. ECDH 密钥交换（已证实框架，待补字节布局）

- 交换命令：**(CmdSet 1, 模块 18(0x12), CmdID 146(0x92))**，即日志中的 "APP->WMS 0x1292"；
  帧类型为 `dji_ble_wifi_encrypt_empty_req/rsp` 系（首帧为空请求触发交换）。
- 流程（`BLEWiFiConfigFetchingLogic::StartECDHExchange`）：
  1. `BLEWiFiCryptoHelper::GenerateECDHKeyPair(pubkey, privkey)`；
  2. 拼接公钥 + 随机数（两次 vector insert）；
  3. 经 `SDKFrameworkUtility::SendData` 通过 BLE 发送；
  4. `OnECDHExchangeResponse` 处理应答（含 `rand_dev`，长度校验失败即中止）。

## 4. 加密栈（已证实）

- **ECDH**：NIST P-256（prime256v1，EVP_PKEY_CTX_ctrl 0x1001 + NID 0x19F），
  公钥未压缩格式（65 字节，0x04 前缀）；
- **共享密钥**：EVP_PKEY_derive；
- **KDF**：HKDF-SHA256（EVP_PKEY_HKDF 0x40C），输出 32 字节；
  - md = SHA-256（ctrl 0x1003）
  - salt = vecA（ctrl 0x1005）
  - ikm = vecC ‖ vecD（拼接后 ctrl 0x1004）
  - **info = `"BLE-WiFi-v1"`**（11 字节 ASCII，ctrl 0x1006，长度 11）
- **派生切分**：32B → `AES-128 key = 前 16B`，`IV = 后 16B`；
- **对称解密**：AES-128-CBC（EVP_aes_128_cbc，DecryptInit/Update/Final）；
- **完整性**：HMAC-SHA256（OpenSSL HMAC）+ `Dji::Common::CreateSignatureWithSHA256`。

## 5. 剩余未知项

1. ECDH 交换请求/应答的**字节级 payload 布局**（公钥+rand_app 的确切偏移与顺序）；
2. `rand_dev`/`rand_app` 在 HKDF 中与 ECDH 共享密钥的拼接角色；
3. get_ssid/get_password **应答的密文格式**（AES-CBC 前 16B 是否为 IV 或使用派生 IV）；
4. HMAC-SHA256 的输入构造（`kKeyTokenPrefix` 常量的角色）；
5. `verify push ok, ACCEPTED` 对应的校验推送步骤。

## 7. 反汇编观察记录（2026-10-25 第一轮）

- `OnECDHExchangeResponse`（0x140F258，2812B）：自身**不做解密**——仅解析应答字段
  （两个 vector 构造 + 两次 assign 存入成员），大量 ostream 日志；实际派生/解密由
  `BLEWiFiCryptoHelper` 的后续调用完成。
- `TryDecryptGlobal`（0x1439600，3516B，879 条指令）：
  - 入口即校验**全局缓存的密钥状态**：BSS `0x2755000+0xBF8` 与 `+0xC00` 两处 16 字节
    向量（`cmp #0x10`）——ECDH 私钥/会话密钥按设备**缓存于全局**，非每次交换；
  - 缓存未就绪（cbz 跳转）时走完整交换分支；缓存命中则直接进入解密路径；
  - 完整控制流需下一轮逐块分析（反汇编已存 `/tmp/mimo-re/notes/disasm_trydecrypt.txt`，
    879 条指令含全部原始字节）。

## 8. 逆向管线（可复用）

- `parse_symbols.py`：手动 ELF64 解析（绕过加固伪造段表）→ PT_DYNAMIC → GNU_HASH → 全量符号；
- `disasm_one.py`：capstone 单函数反汇编（.rela.plt 符号回溯）；
- 依赖：`venv2`（capstone + pyelftools + scapy + dpkt）。

## 6. 实现现状

- `CameraBleWaker`（Swift/CoreBluetooth，`ios/OpenMimoProtocol/Sources/OpenMimoProtocol/CameraBleWake.swift`）：
  已实现**实测验证**的路径——扫描→连接 FFF0→FFF5 发明文 DUML 8 帧序→FFF4 收明文凭据（无认证无 ECDH）；
  代码中保留的 R 认证/唤醒/ECDH 分支为历史实验路径，当前流程不触发。
- 完整链路与帧序表见 [connection-implementation.md](connection-implementation.md)。
