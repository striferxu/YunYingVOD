# -*- coding: utf-8 -*-
"""auth.py — 密码哈希、登录、会话校验、常量时间比较（v2）。纯标准库。

哈希格式（与方案 §5.2 一致）：
  scrypt$16384$8$1$<b64(salt)>$<b64(hash)>
  pbkdf2$200000$<b64(salt)>$<b64(hash)>      # 回退
"""
import base64
import hashlib
import hmac
import os
import secrets

SCRYPT_N = 2 ** 14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 32
SCRYPT_MAXMEM = 64 * 1024 * 1024
PBKDF2_ITERS = 200000


def _b64(b):
    return base64.b64encode(b).decode("ascii")


def _unb64(s):
    return base64.b64decode(s)


def hash_password(password):
    """返回存储格式字符串。优先 scrypt，失败回退 pbkdf2。"""
    if isinstance(password, str):
        password = password.encode("utf-8")
    try:
        salt = os.urandom(16)
        h = hashlib.scrypt(password, salt=salt, n=SCRYPT_N, r=SCRYPT_R,
                           p=SCRYPT_P, dklen=SCRYPT_DKLEN, maxmem=SCRYPT_MAXMEM)
        return "scrypt$%d$%d$%d$%s$%s" % (SCRYPT_N, SCRYPT_R, SCRYPT_P, _b64(salt), _b64(h))
    except (ValueError, AttributeError):
        salt = os.urandom(16)
        h = hashlib.pbkdf2_hmac("sha256", password, salt, PBKDF2_ITERS)
        return "pbkdf2$%d$%s$%s" % (PBKDF2_ITERS, _b64(salt), _b64(h))


def verify_password(password, stored):
    """常量时间校验存储哈希。任何异常一律 False。"""
    if not stored:
        return False
    if isinstance(password, str):
        password = password.encode("utf-8")
    try:
        parts = stored.split("$")
        if parts[0] == "scrypt" and len(parts) == 6:
            n = int(parts[1]); r = int(parts[2]); p = int(parts[3])
            salt = _unb64(parts[4])
            expected = _unb64(parts[5])
            actual = hashlib.scrypt(password, salt=salt, n=n, r=r, p=p,
                                    dklen=len(expected), maxmem=SCRYPT_MAXMEM)
            return hmac.compare_digest(actual, expected)
        if parts[0] == "pbkdf2" and len(parts) == 4:
            iters = int(parts[1])
            salt = _unb64(parts[2])
            expected = _unb64(parts[3])
            actual = hashlib.pbkdf2_hmac("sha256", password, salt, iters)
            return hmac.compare_digest(actual, expected)
    except Exception:
        return False
    return False


def constant_time_eq(a, b):
    """字符串常量时间比较（legacy 老密码兜底用）。"""
    if isinstance(a, str):
        a = a.encode("utf-8")
    if isinstance(b, str):
        b = b.encode("utf-8")
    return hmac.compare_digest(a, b)


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def new_session_token():
    return secrets.token_urlsafe(32)
