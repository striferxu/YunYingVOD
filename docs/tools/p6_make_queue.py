"""P6 验收：构造转码排队（queued）状态。

服务端转码单并发（MAX_CONCURRENT_JOBS=1，契约 §4.1）。
用 1080p 长视频占住转码线程，让 App 端上传的小任务停在 queued。
"""
import json, urllib.request, urllib.error, subprocess, os, io

BASE = 'http://127.0.0.1:8000'
SRC = '/tmp/p6_queue_long.mp4'


def login():
    req = urllib.request.Request(
        BASE + '/api/login',
        data=json.dumps({'username': 'user', 'password': '123456'}).encode(),
        headers={'Content-Type': 'application/json'})
    r = urllib.request.urlopen(req)
    raw = r.headers.get_all('Set-Cookie') or []
    return '; '.join(c.split(';')[0] for c in raw)


def upload(cookie, path, title):
    boundary = '----p6queue'
    body = io.BytesIO()
    body.write(('--%s\r\n' % boundary).encode())
    body.write(b'Content-Disposition: form-data; name="video"; filename="queue_long.mp4"\r\n')
    body.write(b'Content-Type: video/mp4\r\n\r\n')
    with open(path, 'rb') as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            body.write(chunk)
    body.write(('\r\n--%s\r\n' % boundary).encode())
    body.write(b'Content-Disposition: form-data; name="title"\r\n\r\n')
    body.write(title.encode())
    body.write(('\r\n--%s--\r\n' % boundary).encode())

    req = urllib.request.Request(
        BASE + '/api/upload', data=body.getvalue(),
        headers={'Content-Type': 'multipart/form-data; boundary=%s' % boundary,
                 'Cookie': cookie})
    try:
        r = urllib.request.urlopen(req)
        return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


if not os.path.exists(SRC):
    print('生成 1080p / 900 秒占位源（转码会较慢）…')
    subprocess.run([
        'ffmpeg', '-y',
        '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30:duration=900',
        '-f', 'lavfi', '-i', 'sine=frequency=280:duration=900',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '2500k',
        '-c:a', 'aac', '-b:a', '96k', SRC,
    ], check=True, capture_output=True)
    print('源大小: %.1f MB' % (os.path.getsize(SRC) / 1048576))

cookie = login()
st, d = upload(cookie, SRC, 'P6-queue-long-occupier')
print('占位任务:', st, d)
