import json, urllib.request, urllib.error, io

BASE = 'http://127.0.0.1:8000'

# 登录并手工取 Set-Cookie（cookiejar 会因 Secure 属性在 http 下不发送）
req = urllib.request.Request(
    BASE + '/api/login',
    data=json.dumps({'username': 'user', 'password': '123456'}).encode(),
    headers={'Content-Type': 'application/json'})
r = urllib.request.urlopen(req)
raw = r.headers.get_all('Set-Cookie') or []
cookie = '; '.join(c.split(';')[0] for c in raw)
print('登录:', r.status, 'cookie 条数:', len(raw))


def upload(filename, content, ctype='text/plain'):
    boundary = '----p6test'
    body = io.BytesIO()
    body.write(('--%s\r\n' % boundary).encode())
    body.write(('Content-Disposition: form-data; name="video"; filename="%s"\r\n'
                % filename).encode())
    body.write(('Content-Type: %s\r\n\r\n' % ctype).encode())
    body.write(content)
    body.write(('\r\n--%s\r\n' % boundary).encode())
    body.write(b'Content-Disposition: form-data; name="title"\r\n\r\n')
    body.write('P6非法文件测试'.encode())
    body.write(('\r\n--%s--\r\n' % boundary).encode())

    req = urllib.request.Request(
        BASE + '/api/upload',
        data=body.getvalue(),
        headers={
            'Content-Type': 'multipart/form-data; boundary=%s' % boundary,
            'Cookie': cookie,
        })
    try:
        resp = urllib.request.urlopen(req)
        return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


print('\n=== 1) 上传 .txt（扩展名不支持）===')
print(upload('notvideo.txt', b'not a video'))

print('\n=== 2) 上传 .mp4 但内容为空 ===')
print(upload('empty.mp4', b'', 'video/mp4'))

print('\n=== 3) 上传 .jpg（图片伪装）===')
print(upload('photo.jpg', b'\xff\xd8\xff\xe0fakejpeg', 'image/jpeg'))
