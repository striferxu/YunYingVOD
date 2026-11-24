# 决策记录（P0 阶段问题已全部确认）

> 状态：**全部已决策，无阻塞项**。原问题保留作为决策留痕。

---

## Q1 注册功能 ✅ 已决策

**站长答复**："网站是允许注册，但是要管理员确认（界面如图所示）"

**实测发现**：Web 前端有完整注册表单，但后端 `SITEAUTH_ALLOW_REGISTER=0`，
导致 `POST /api/register` 返回 `403 registration closed`。
即**线上注册功能当时是坏的**——网页上提交必然失败。

**已执行**：
1. `SITEAUTH_ALLOW_REGISTER` 0 → 1，`systemctl restart siteauth`
2. 备份：`/root/site-backups/env.conf.bak_<时间>`
3. 全流程实测通过（正常注册 / 重复用户名 / 非法用户名 / 无密码 / 昵称超长 / pending 登录）
4. 测试用户已清理

**结论**：客户端 P7 按**完整注册表单**实现，UI 对齐 Web 端截图（见 `CLIENT_API_SPEC.md` §5.2）。

---

## Q2 App 长效 token ✅ 已决策

| 项 | 决策 |
|----|------|
| 有效期 | **30 天**（不是原计划的 90 天） |
| 设备管理 | **需要**（查看已授权设备列表 + 踢掉指定设备） |
| 改密码作废旧 token | 是（默认安全行为） |

**对 P1 工作量影响**：原计划 2 个接口，现需 4 个：
- `POST /api/app/token` 换发
- `POST /api/app/session` 静默换 session
- `GET /api/app/tokens` 列出本用户已授权设备
- `DELETE /api/app/tokens/<id>` 作废指定设备
- （改密码时批量删除该用户全部 token）

`app_tokens` 表需包含：`token_hash`、`user_id`、`device`、`created_at`、
`last_used_at`、`last_used_ip`、`expires_at`。

---

## Q3 GitHub 仓库 ✅ 已决策

| 项 | 决策 |
|----|------|
| 仓库名 | `YunYingVOD` |
| 可见性 | **公开（public）** |
| 创建方式 | **我用 PAT 创建** |

**待站长提供**：GitHub Personal Access Token（需 `repo` 权限，用于建仓 + push）。

> 安全提示：token 仅用于本次建仓与推送，将写入本机 git remote 的临时凭据；
> 完成后建议在 GitHub 设置中撤销该 token，或改用 SSH key。

---

## Q4 已知限制 ✅ 已接受

| 限制 | 说明 |
|------|------|
| 蜂窝网络上传 >300 秒被服务端掐断 | 客户端提示"建议 WiFi 上传"，不做断点续传（后端不支持） |
| 转码单并发 | 多人同时上传需排队，客户端展示 `queued` 状态 |
| admin 功能不做进 App | 用户审核、视频管理仍用 Web 端 |

---

## 附：P0 阶段对生产环境的唯一变更

| 时间 | 变更 | 影响 |
|------|------|------|
| 2026-11-24 23:36 | `SITEAUTH_ALLOW_REGISTER` 0 → 1，重启 siteauth | 修复线上注册故障；服务中断约 2 秒 |

测试产生的探针视频、注册用户、上传任务均已清理，环境已复原（33 条 ready、仅 admin/user 两账号）。
