import sqlite3, os, glob

conn = sqlite3.connect('/opt/siteauth/site.db')

print('=== 新视频归属 ===')
row = conn.execute(
    'SELECT v.id, v.name, v.owner_id, u.username, v.status '
    'FROM videos v LEFT JOIN users u ON u.id = v.owner_id '
    "WHERE v.id = '9c8532f8'").fetchone()
print(row)

print('\n=== 媒体文件位置 ===')
hits = glob.glob('/opt/siteauth/**/9c8532f8*', recursive=True)[:10]
for h in hits:
    print(h, os.path.getsize(h) if os.path.isfile(h) else '<dir>')
if not hits:
    for base in ('/opt/siteauth/media', '/opt/siteauth/videos', '/opt/siteauth/data'):
        if os.path.isdir(base):
            print('base:', base, os.listdir(base)[:5])

print('\n=== m3u8 内容前 5 行 ===')
for h in hits:
    if h.endswith('.m3u8'):
        with open(h) as f:
            print(''.join(f.readlines()[:5]))
        break

print('\n=== 全部 ready 视频数 ===')
print(conn.execute("SELECT COUNT(*) FROM videos WHERE status='ready'").fetchone())
