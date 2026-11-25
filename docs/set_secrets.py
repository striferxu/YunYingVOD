"""把 4 个 Actions Secret 写入 GitHub 仓库（HTTP 用 curl，加密用 PyNaCl）。

用法：python set_secrets.py <token>
从环境变量读取值，避免口令出现在命令行参数里：
  SECRET_KEYSTORE_B64 / SECRET_STORE_PASS / SECRET_KEY_PASS / SECRET_ALIAS

为什么用 curl：本机 Python 的 SSL 根证书链不完整（CERTIFICATE_VERIFY_FAILED），
而系统 curl 正常。
"""
import base64
import json
import os
import subprocess
import sys

from nacl import encoding, public

REPO = 'striferxu/YunYingVOD'
API = 'https://api.github.com'


def curl(method, path, token, body=None):
    cmd = [
        'curl', '-sS', '-X', method,
        '-H', 'Authorization: Bearer ' + token,
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2022-11-28',
        '-w', '\n%{http_code}',
        API + path,
    ]
    if body is not None:
        cmd += ['-H', 'Content-Type: application/json', '-d', json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        print('curl 失败:', out.stderr[:400])
        sys.exit(1)
    raw, _, code = out.stdout.rpartition('\n')
    try:
        return int(code), (json.loads(raw) if raw.strip() else {})
    except json.JSONDecodeError:
        return int(code), {'raw': raw[:400]}


def main():
    token = sys.argv[1]
    secrets = {
        'KEYSTORE_BASE64': os.environ['SECRET_KEYSTORE_B64'],
        'KEYSTORE_PASSWORD': os.environ['SECRET_STORE_PASS'],
        'KEY_PASSWORD': os.environ['SECRET_KEY_PASS'],
        'KEY_ALIAS': os.environ['SECRET_ALIAS'],
    }

    st, pk = curl('GET', f'/repos/{REPO}/actions/secrets/public-key', token)
    print('public-key HTTP', st)
    if st != 200:
        print(pk)
        sys.exit(1)
    key_id = pk['key_id']

    sealed = public.SealedBox(
        public.PublicKey(pk['key'].encode(), encoding.Base64Encoder))

    for name, value in secrets.items():
        enc = base64.b64encode(sealed.encrypt(value.encode())).decode()
        st, body = curl('PUT', f'/repos/{REPO}/actions/secrets/{name}', token, {
            'encrypted_value': enc,
            'key_id': key_id,
        })
        ok = st in (201, 204)
        print(f'  {name}: HTTP {st}', '' if ok else body)
        if not ok:
            sys.exit(1)

    st, lst = curl('GET', f'/repos/{REPO}/actions/secrets', token)
    print('\n=== 仓库现有 Secrets ===')
    if st == 200:
        for s in lst.get('secrets', []):
            print('  -', s['name'], '| updated:', s['updated_at'])
    else:
        print('  读取失败', st, lst)


if __name__ == '__main__':
    main()
