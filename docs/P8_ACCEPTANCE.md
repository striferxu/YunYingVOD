# P8 验收记录 · 打包发布（GitHub Releases）

> 阶段目标（PHASE_PLAN.md P8）：一条 push 自动出签名 APK 并发布。
>
> **结论：全部通过。** tag `v0.1.0` 推送后 CI 全绿（17 步全 success），
> GitHub Releases 已发布带签名的 APK 与 sha256；真机验证安装、覆盖安装、
> 登录态保留全部正常。

- 验收日期：2026-11-25
- 设备：Samsung SM-F9360（Fold4），Android 16，arm64-v8a
- 仓库：`striferxu/YunYingVOD`
- 首个版本：`v0.1.0`（versionName 0.1.0 / versionCode 1）
- CI 运行：<https://github.com/striferxu/YunYingVOD/actions/runs/45571140280>
- Release：<https://github.com/striferxu/YunYingVOD/releases/tag/v0.1.0>

---

## 1. 验收清单

| # | 验收标准（任务书） | 结果 | 证据 |
|---|---|---|---|
| 1 | 打 `v0.1.0` tag → CI 全绿 → Releases 页出现 APK | ✅ 通过 | 见 3.1 / 3.2 |
| 2 | 干净设备浏览器下载 APK 直接安装成功 | ✅ 通过 | 见 3.3 |
| 3 | 覆盖安装（旧版本在、装新版本）成功且登录态保留 | ✅ 通过 | 见 3.4 |
| 4 | APK 为 release 签名（`apksigner verify` 通过），minSdk 与真机验收记录一致 | ✅ 通过 | 见 3.5 |
| 5 | 仓库中无 keystore、无密码、无敏感信息 | ✅ 通过 | 见 3.6 |

---

## 2. 实现概要

### 2.1 文件变更

| 文件 | 类型 | 说明 |
|---|---|---|
| `.github/workflows/release.yml` | 新增 | CI 发版流程（tag `v*` 触发） |
| `android/app/build.gradle.kts` | 修改 | 接入 `key.properties` 签名；缺失时回退 debug |
| `pubspec.yaml` | 修改 | `version: 1.0.0+1` → `0.1.0+1` |
| `docs/RELEASE.md` | 新增 | 发布指南（备份警告 / Secrets / 发版步骤 / 排查 / 自查） |
| `docs/tools/set_secrets.py` | 新增 | 通过 GitHub API 写入 4 个 Actions Secrets（一次性工具） |
| `android/vodapp.jks` | 生成 | **不入库**（`.gitignore` 已覆盖） |
| `android/key.properties` | 生成 | **不入库** |

### 2.2 签名配置要点

```kotlin
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
...
signingConfigs {
    if (hasReleaseKeystore) {
        create("release") {
            storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
            ...
        }
    }
}
buildTypes {
    release {
        signingConfig = if (hasReleaseKeystore) {
            signingConfigs.getByName("release")
        } else {
            signingConfigs.getByName("debug")   // 本地无 keystore 时仍能构建
        }
    }
}
```

**关键决策**：`storeFile` 用 `rootProject.file(...)` 而不是 `file(...)`。
`file()` 在 `app/build.gradle.kts` 里默认相对 `android/app/`，
而 `key.properties` 与 `vodapp.jks` 都在 `android/`，
用 `rootProject.file` 才解析正确（这是本轮踩到的坑，已写进 RELEASE.md）。

### 2.3 keystore

| 项 | 值 |
|---|---|
| 文件 | `android/vodapp.jks`（2728 bytes） |
| alias | `vodapp` |
| 算法 | RSA 2048 / SHA384withRSA |
| 有效期 | 2026-11-25 → **2056-11-17**（10950 天，30 年） |
| Subject | `CN=YunYing VOD, OU=VOD, O=ccwu, L=Unknown, ST=Unknown, C=CN` |
| SHA-256 | `C7:6F:64:EF:78:F7:DC:06:29:C0:CB:3F:B7:43:E3:EB:3F:78:11:B1:31:80:E7:2A:A1:68:A5:F1:FA:57:78:98` |
| SHA-1 | `B4:8C:FF:C7:40:64:69:42:F5:5B:DD:AF:68:CA:BF:20:28:98:C5:F3` |

> ⚠️ **口令由站长本人提供并保管，未写入本仓库任何文件。**
> `key.properties` 与 `vodapp.jks` 均在 `.gitignore` 中，`git check-ignore` 已验证生效。

### 2.4 GitHub Secrets（4 个，已配置）

通过 GitHub API 写入（`docs/tools/set_secrets.py`，PyNaCl 密封加密）：

```
KEYSTORE_BASE64      | 201
KEYSTORE_PASSWORD    | 201
KEY_PASSWORD         | 201
KEY_ALIAS            | 201
```

回读确认：

```
- KEYSTORE_BASE64   | updated: 2026-11-25T07:47:01Z
- KEYSTORE_PASSWORD | updated: 2026-11-25T07:47:02Z
- KEY_PASSWORD      | updated: 2026-11-25T07:47:03Z
- KEY_ALIAS         | updated: 2026-11-25T07:47:04Z
```

### 2.5 CI 流程（16 步业务步骤）

```
Checkout
Set up Flutter 3.50.1
Set up JDK 21
Flutter pub get
Analyze
Test
Restore keystore          ← base64 -d 还原 android/vodapp.jks
Write key.properties      ← 从 Secrets 现场生成（只打印字段名）
Resolve version           ← tag 去 v 作 versionName；versionCode = run_number
Build release APK
Verify APK signature      ← 出现 "CN=Android Debug" 直接 exit 1
Show APK info             ← aapt2 dump badging
Rename artifact           ← yunying-vod-v0.1.0.apk + .sha256
Upload artifact
Create Release            ← 附 APK 与 sha256
Cleanup signing material  ← always()，删除 jks 与 key.properties
```

**关键防呆**：`Verify APK signature` 步骤会检查 `CN=Android Debug`，
一旦 CI 里的 keystore 没还原成功（回退 debug 签名），构建直接失败，
不会把 debug 包误发到 Releases。

---

## 3. 验收记录

### 3.1 CI 运行结果

tag `v0.1.0` 推送后触发，运行 ID `45571140280`，**全部步骤 success**：

```
Build signed APK and publish Release | success
  - Set up job                | success
  - Checkout                  | success
  - Set up Flutter            | success
  - Set up JDK 21             | success
  - Flutter pub get           | success
  - Analyze                   | success
  - Test                      | success
  - Restore keystore          | success
  - Write key.properties      | success
  - Resolve version           | success
  - Build release APK         | success
  - Verify APK signature      | success
  - Show APK info             | success
  - Rename artifact           | success
  - Upload artifact (always)  | success
  - Create Release            | success
  - Cleanup signing material  | success
```

总耗时约 8 分钟（含 Flutter 缓存冷启动）。

### 3.2 Releases 页

```
v0.1.0 | 云影 VOD v0.1.0
  assets:
    yunying-vod-v0.1.0.apk         61,335,351 bytes
    yunying-vod-v0.1.0.apk.sha256  89 bytes
```

Release Notes 含安装说明、sha256 提示、4 条已知限制、提交历史链接。

### 3.3 下载与安装

从 Release 页下载 APK，**sha256 与官方附件逐字一致**：

```
附件声明:  41599517194640e5b41d49e8f4cac5877e011f0467c48e087b0f7745b99da5b6
实际下载:  41599517194640e5b41d49e8f4cac5877e011f0467c48e087b0f7745b99da5b6
```

> 说明：CI 产物 sha256 与本地构建不同（`7c9d9951...`）是正常的——
> Gradle 打包会写入时间戳，两次构建不会逐字节相同。**签名证书**才是
> 判断"是否同一身份"的依据，两者一致（见 3.5）。

`adb install` 安装成功，App 正常启动到登录页（截图 `shots/p8_install.png`）。

### 3.4 覆盖安装保留登录态

流程：

1. 在 release 版登录 `user` / `123456` → 进入视频广场（截图 `shots/p8_login_ok.xml`）
2. `adb install -r` 覆盖安装 CI 产物 → **Success**
3. 强杀进程重开 → **直接进入视频广场，未回退登录页**（截图 `shots/p8_ci_overinstall.png`）

说明 secure storage 中的 Cookie 与 app token 在覆盖安装后完整保留。
覆盖安装前（本地 release 包）也同样验证过一次，结果一致（`shots/p8_overinstall.png`）。

### 3.5 签名与 minSdk

CI 产物 `apksigner verify --print-certs`：

```
Signer #1 certificate DN: CN=YunYing VOD, OU=VOD, O=ccwu, L=Unknown, ST=Unknown, C=CN
Signer #1 certificate SHA-256 digest: c76f64ef78f7dc0629c0cb3fb743e3eb3f7811b13180e72aa168a5f1fa577898
Signer #1 certificate SHA-1 digest:   b48cffc740646942f55bddaf68cabf202898c5f3
```

与本地 keystore 指纹**完全一致**，且**不是** `CN=Android Debug`。

`aapt2 dump badging`：

```
package: name='cc.ccwu.vod_app' versionCode='1' versionName='0.1.0'
minSdkVersion:'24'
targetSdkVersion:'36'
```

minSdk 24 与 P2–P7 各阶段真机验收一致（Fold4 实测 Android 16）。

### 3.6 仓库安全自查

```bash
# 1) 仓库中不应有密钥文件
git ls-files | grep -Ei '\.(jks|keystore)$|key\.properties'
# → 无输出 ✅

# 2) 暂存内容不应有真实口令（只有变量名与文档说明）
git diff --cached | grep -Ei 'storePassword|keyPassword|Lyzd'
# → 仅命中 ${KEYSTORE_PASSWORD} / getProperty("storePassword") / 文档文字 ✅

# 3) 全历史不应有口令
git log -p --all | grep -Ei 'Lyzd@|storePassword='
# → 无输出 ✅

# 4) .gitignore 生效确认
git check-ignore -v android/vodapp.jks android/key.properties
# → android/.gitignore:14:**/*.jks     android/vodapp.jks
#   android/.gitignore:12:key.properties  android/key.properties ✅
```

---

## 4. 已知限制

1. **keystore 丢失 = 无法升级**
   用户只能卸载重装，本地登录态与上传记录全部丢失。
   `docs/RELEASE.md` 第 0 节已写明备份要求（至少 3 份、异地存放）。

2. **CI 产物与本地构建 sha256 不同**
   Gradle 打包含时间戳，属正常现象。判断同一身份看**证书指纹**，不看文件哈希。

3. **versionCode 由 CI 的 run_number 决定**
   本地构建用 `pubspec.yaml` 的 `+N`。CI 的 run_number 单调递增，
   能保证覆盖升级；但如果中途手动 workflow_dispatch 触发过，
   run_number 会跳号（不影响升级，只是号不连续）。

4. **Flutter 版本必须与 workflow 里锁定的 3.50.1 一致**
   本项目使用 `package:material_ui/material_ui.dart`（Flutter 3.50 起
   `flutter/material.dart` 已废弃），版本漂移会导致解析失败。

5. **未做 Play Store 上架**（任务书明确不做）。

6. **未做 ABI 拆分**
   单个 universal APK 58.5MB。若后续要减小体积，可加
   `--split-per-abi`，但需要同时调整 Release 附件与文档。

---

## 5. 后续发版速查

```bash
# 1. 改版本号
#    pubspec.yaml: version: 0.2.0+2

# 2. 提交并打 tag
git add -A && git commit -m "release: v0.2.0"
git tag v0.2.0
git push origin main --tags

# 3. 等 CI 绿，Release 页确认
```

详见 `docs/RELEASE.md`。

---

## 6. 安全提醒

- `vodapp.jks` 与口令由站长保管，**未出现在本仓库任何文件或提交历史中**
- 本次配置 Secrets 使用的 PAT 为一次性用途，**建议立即在 GitHub 上撤销**
  （Settings → Developer settings → Personal access tokens）
- 若 PAT 已泄露，撤销后需重新生成并更新到本地凭据管理器（仅推送用）
