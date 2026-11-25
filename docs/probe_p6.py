import sqlite3

conn = sqlite3.connect('/opt/siteauth/site.db')
print('=== 最近 3 条视频 ===')
for r in conn.execute(
    'SELECT id, name, status, duration, size_bytes, created_at '
    'FROM videos ORDER BY created_at DESC LIMIT 3'):
    print(r)

print('\n=== 最近 3 条上传任务 ===')
try:
    cols = [c[1] for c in conn.execute('PRAGMA table_info(upload_jobs)')]
    print('列:', cols)
    for r in conn.execute(
        'SELECT id, user_id, title, status, total_seconds, result_id '
        'FROM upload_jobs ORDER BY created_at DESC LIMIT 3'):
        print(r)
except Exception as e:
    print('upload_jobs 查询失败:', e)

print('\n=== 用户表 ===')
for r in conn.execute('SELECT id, username, nickname, role FROM users LIMIT 5'):
    print(r)

print('\n=== 视频 owner 关联 ===')
try:
    for r in conn.execute(
        'SELECT v.id, v.name, o.user_id FROM videos v '
        'LEFT JOIN video_owners o ON o.video_id = v.id '
        'ORDER BY v.created_at DESC LIMIT 3'):
        print(r)
except Exception as e:
    print('owner 查询失败:', e)
