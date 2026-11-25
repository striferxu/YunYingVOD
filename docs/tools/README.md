# docs/tools · 一次性运维与探针脚本（历史留档）

这些脚本是 P0–P8 阶段为验收而写的**一次性工具**，已在服务器/本机实际执行过，
结果已固化进各阶段验收文档。**它们不属于 App 构建产物，也不参与 CI**。

保留原因：接口回归、故障复现、发版排障时可以直接复跑，不必重写。
清理原则：能复跑的探针保留；纯一次性数据清理脚本保留但标注"已完成、勿再跑"。

## 目录

| 脚本 | 阶段 | 用途 | 复跑性 |
|---|---|---|---|
| `probe_p0.py` / `probe_p0b~e.py` | P0 | 接口契约逐条实测（登录、列表、m3u8、key、错误码） | ✅ 可复跑（只读） |
| `probe_p1.py` | P1 | app token 4 接口 + 作废链路（25/25） | ⚠️ 会签发/删除 token，可复跑 |
| `probe_p3.py` | P3 | 会话全链路 16 项断言 | ⚠️ 会签发/踢 token，可复跑 |
| `probe_dedup.py` | P3.1 | 设备去重回归（5/5） | ⚠️ 会写库后自清理 |
| `probe_revoke.py` | P3.2 | 踢设备后登录态失效回归（11/11） | ⚠️ 会写库后自清理 |
| `probe_p6.py` / `probe_p6b.py` | P6 | 上传与转码状态查询 | ✅ 只读 |
| `probe_p6_login.py` / `probe_p6_jobs.py` / `probe_p6_times.py` / `probe_p6_txt.py` / `probe_p6_web.py` | P6 | 排障用的小探针（登录、任务列表、时间戳、文本输出、Web 端对照） | ✅ 只读 |
| `probe_p7.py` | P7 | 注册接口 8 组边界用例 | ⚠️ 会创建 pending 用户，需手动清理 |
| `p6_make_queue.py` | P6 | 制造转码排队（占住单并发） | ❌ 一次性，已完成 |
| `fix_p6_keyuri.py` | P6 | 修正历史视频 m3u8 的 key URI（绝对→相对） | ❌ 一次性，已完成（线上已修） |
| `cleanup_p6.py` | P6 | 清理 P6 排队测试数据与媒体目录 | ❌ 一次性，已完成 |
| `set_secrets.py` | P8 | 通过 GitHub API 写入 4 个 Actions Secrets | ❌ 一次性，已完成（PAT 应已撤销） |

## 运行前提

- 探针必须在**服务器本机**跑（`python3 xxx.py`），因为本机到 `51play.ccwu.cc`
  的连接会被网络按 SNI 阻断（见 `../P5_ACCEPTANCE.md` 第 6 节）。
- 部分脚本依赖服务器上的 `siteauth` 模块与 `site.db`，只读脚本不受影响。
- `set_secrets.py` 需要 PyNaCl（`python -m pip install pynacl`）与 `curl`，
  且需要一次性 PAT；**当前已完成配置，不要再跑**。

## 注意

- 这些脚本里出现过测试账号 `user` / `123456`（站长自定，非机密）。
- **任何脚本都不含 keystore 口令或 GitHub PAT**，口令只通过环境变量/命令行传入。
- 若要重新整理文档目录，请保留本文件，其余阶段文档中的引用路径已同步更新。
