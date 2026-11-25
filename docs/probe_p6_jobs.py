import sqlite3
conn = sqlite3.connect('/opt/siteauth/site.db')
print('=== 最近 5 条上传任务 ===')
for r in conn.execute(
        'SELECT id, title, status, created_at FROM upload_jobs '
        'ORDER BY created_at DESC LIMIT 5'):
    print(' ', r)
print('\n=== 当前 running 的任务 ===')
for r in conn.execute(
        "SELECT id, title, status FROM upload_jobs WHERE status='running'"):
    print(' ', r)
print('\n=== 当前 queued 的任务 ===')
for r in conn.execute(
        "SELECT id, title, status FROM upload_jobs WHERE status='queued'"):
    print(' ', r)
