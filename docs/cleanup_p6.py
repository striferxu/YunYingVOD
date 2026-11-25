import sqlite3, os, shutil, glob

conn = sqlite3.connect('/opt/siteauth/site.db')

# 保留 9c8532f8（4P6test100MB，主验收证据），其余为排队测试产生的临时数据
CLEAN_IDS = ['56427437', '815ec1f0', '4f5fb9a2', 'f072901b', '8d1addc4', '2eb6ca65']

print('=== 待清理 ===')
rows = conn.execute(
    'SELECT id, name FROM videos WHERE id IN (%s)' % ','.join('?' * len(CLEAN_IDS)),
    CLEAN_IDS).fetchall()
for r in rows:
    print('  video:', r)
jobs = conn.execute(
    'SELECT id, title, status FROM upload_jobs WHERE id IN (%s)'
    % ','.join('?' * len(CLEAN_IDS)), CLEAN_IDS).fetchall()
for r in jobs:
    print('  job  :', r)

for vid in CLEAN_IDS:
    conn.execute('DELETE FROM videos WHERE id=?', (vid,))
    conn.execute('DELETE FROM upload_jobs WHERE id=?', (vid,))
conn.commit()
print('\nDB 已清理')

removed = []
for vid in CLEAN_IDS:
    d = '/var/www/html/videos/%s' % vid
    if os.path.isdir(d):
        shutil.rmtree(d)
        removed.append(d)
    k = '/var/www/html/key/%s' % vid
    if os.path.lexists(k):
        os.unlink(k)
        removed.append(k)
print('已删除文件:', removed)

for f in glob.glob('/tmp/p6_queue*.mp4'):
    os.unlink(f)
    print('已删除临时源:', f)

print('\n=== 清理后统计 ===')
print('ready 视频数:', conn.execute(
    "SELECT COUNT(*) FROM videos WHERE status='ready'").fetchone()[0])
print('剩余 upload_jobs:', conn.execute('SELECT COUNT(*) FROM upload_jobs').fetchone()[0])
print('保留的主验收视频:')
for r in conn.execute(
        "SELECT id, name, owner_id FROM videos WHERE id='9c8532f8'"):
    print(' ', r)
