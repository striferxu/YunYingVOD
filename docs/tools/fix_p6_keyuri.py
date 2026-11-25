import ast, sqlite3, os, re, glob, shutil

# 1) 语法校验
src = open('/opt/siteauth/multiuser.py').read()
ast.parse(src)
print('[1] multiuser.py 语法 OK')
print('    key URI 写法:', [l.strip() for l in src.splitlines()
                        if '/key/%s' in l])

# 2) 修复已生成的绝对 URL m3u8（把 https://<host>/key/<id> 改回 /key/<id>）
fixed = []
for m3u8 in glob.glob('/var/www/html/videos/*/output.m3u8'):
    body = open(m3u8).read()
    new = re.sub(r'URI="https?://[^/"]+/key/', 'URI="/key/', body)
    if new != body:
        shutil.copy2(m3u8, m3u8 + '.bak_p6')
        open(m3u8, 'w').write(new)
        fixed.append(m3u8)

print('\n[2] 已修复绝对 URL 的 m3u8:', fixed or '（无，全部已是相对路径）')

# 3) 复查所有视频的 key URI 形态
print('\n[3] 全部视频 key URI 检查:')
bad = 0
for m3u8 in sorted(glob.glob('/var/www/html/videos/*/output.m3u8')):
    body = open(m3u8).read()
    m = re.search(r'#EXT-X-KEY:METHOD=AES-128,URI="([^"]+)"', body)
    uri = m.group(1) if m else '<无>'
    vid = os.path.basename(os.path.dirname(m3u8))
    ok = uri.startswith('/key/')
    if not ok:
        bad += 1
    print('  %-30s %s %s' % (vid, 'OK ' if ok else 'BAD', uri))
print('\n异常数量:', bad)
