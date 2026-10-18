#!/usr/bin/env python3
"""Samsung SysDump (*#9900#) OTP 生成器
算法来源: https://gist.github.com/JaapBosheuvel/1e7e7ef8c02f6d6a4989ccfe330c38d6
用法: python3 sysdump-otp.py <弹窗显示的key>
"""
import hmac, hashlib, time, sys

SECRET_KEY_HEX = "120395F099840593405B03838449A72933484040A3034750C0403938290A293B"
SECRET = bytes.fromhex(SECRET_KEY_HEX)
TIME_STEP = 300

def gen(key: str, window_offset: int = 0) -> tuple[str, int]:
    nonce = key[2:] if len(key) >= 2 else ""
    now = int(time.time())
    time_step = now // TIME_STEP + window_offset
    time_hex = format(time_step, "X").upper().zfill(16)
    if len(nonce) == 6 and nonce.isdigit():
        msg_hex = (nonce + time_hex).zfill(22)
    else:
        msg_hex = time_hex.zfill(16)
    h = hmac.new(SECRET, bytes.fromhex(msg_hex), hashlib.sha256).digest()
    off = h[-1] & 0x0F
    val = int.from_bytes(h[off:off + 4], "big") & 0x7FFFFFFF
    otp = str(val % 1_000_000).zfill(6)
    remaining = TIME_STEP - (now % TIME_STEP) - window_offset * TIME_STEP
    return otp, remaining

if __name__ == "__main__":
    key = sys.argv[1] if len(sys.argv) > 1 else ""
    for w in range(2):
        otp, rem = gen(key, w)
        label = "当前窗口" if w == 0 else "备用(下一窗口)"
        print(f"{label}: {otp}  (剩余 ~{max(rem, 0)} 秒)")
