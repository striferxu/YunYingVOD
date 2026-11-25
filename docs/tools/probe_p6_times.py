import sqlite3, time
conn = sqlite3.connect('/opt/siteauth/site.db')
print('=== 最近 6 条任务（含时间戳）===')
rows = conn.execute(
    'SELECT id, title, status, created_at, started_at, finished_at FROM upload_jobs '
    'ORDER BY created_at DESC LIMIT 6').fetchall()
for r in rows:
    jid, title, st, c, s, f = r
    dur = (f - s) if (s and f) else None
    wait = (s - c) if (s and c) else None
    print('  %-10s %-20s %-8s 排队=%ss 转码=%ss' %
          (jid, title[:20], st, wait, dur))
