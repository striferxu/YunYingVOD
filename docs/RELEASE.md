# 发布指南（P8）

> 面向站长本人。读完这篇就能完成一次发版。

---

## ⚠️ 第一件事：备份 keystore

`vodapp.jks` 是**应用的身份**。Android 只允许"签名相同"的 APK 覆盖安装。

**丢失或口令遗忘的后果**：已安装的用户**无法升级**，只能卸载重装
（本地登录态、上传记录全部丢失），且旧版本无法再从你的手上更新。

所以：

1. `vodapp.jks` **至少备份 3 份**，放在不同位置（本地加密盘、离线 U 盘、密码管理器附件）
2. 口令（storePassword / keyPassword）**单独**存进密码管理器
3. **永远不要**把 `vodapp.jks` 或口令提交进 Git、发到聊天群、贴进 issue
4. 换电脑前先确认备份可用

> 校验备份是否可用：
> ```bash
> keytool -list -v -keystore vodapp.jks -alias vodapp
> ```
> 能正常列出证书信息 = 备份完好。

---

## 1. 文件与位置

| 文件 | 位置 | 是否入库 | 说明 |
|---|---|---|---|
| `vodapp.jks` | `android/vodapp.jks` | ❌ **绝不** | 签名密钥库 |
| `key.properties` | `android/key.properties` | ❌ **绝不** | 口令与别名（`.gitignore` 已覆盖） |
| `release.yml` | `.github/workflows/release.yml` | ✅ | CI 发版流程 |
| `pubspec.yaml` | 根目录 | ✅ | `version:` 决定 versionName |

`.gitignore` 里已有这几条，**不要删**：

```
*.jks
*.keystore
key.properties
```

---

## 2. keystore 生成（只做一次）

```bash
cd android
keytool -genkeypair -v \
  -keystore vodapp.jks \
  -alias vodapp \
  -keyalg RSA -keysize 2048 -validity 10950 \
  -storepass <STORE_PASSWORD> \
  -keypass  <KEY_PASSWORD>
```

- `-validity 10950` = 30 年。Google 要求至少到 2033 年，30 年足够。
- `-alias vodapp`：**必须记住**，CI 里要用。
- `-keyalg RSA -keysize 2048`：兼容性最好的组合。

生成后 `android/key.properties` 内容：

```properties
storePassword=<STORE_PASSWORD>
keyPassword=<KEY_PASSWORD>
keyAlias=vodapp
storeFile=vodapp.jks
```

> `storeFile` 相对 **`android/`** 解析（`build.gradle.kts` 用 `rootProject.file(...)`），
> 所以 `vodapp.jks` 放在 `android/vodapp.jks`，`storeFile` 写 `vodapp.jks` 即可。
> CI 也是按这个约定把 keystore 写到 `android/vodapp.jks`。

---

## 3. GitHub Secrets（4 个）

仓库 → Settings → Secrets and variables → Actions → New repository secret

| Secret 名 | 值 |
|---|---|
| `KEYSTORE_BASE64` | `vodapp.jks` 的 base64 单行字符串（见下） |
| `KEYSTORE_PASSWORD` | storePassword |
| `KEY_PASSWORD` | keyPassword |
| `KEY_ALIAS` | `vodapp` |

生成 base64（**Windows PowerShell**）：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("android\vodapp.jks")) | Set-Content keystore.b64
```

Linux / macOS：

```bash
base64 -w0 android/vodapp.jks > keystore.b64
```

把 `keystore.b64` 的**整行内容**粘进 `KEYSTORE_BASE64`，然后**删除本地 `keystore.b64`**。

> 注意：GitHub 的 secret 一旦保存就无法再读出原值，只能覆盖。填错了就重新填一遍。

---

## 4. 发版步骤

### 4.1 改版本号

编辑 `pubspec.yaml`：

```yaml
version: 0.1.0+1
#        ^^^^^  ^
#        |      versionCode（每次发版必须递增，否则无法覆盖安装）
#        versionName
```

> CI 里 versionCode 用 `github.run_number` 覆盖，所以本地这个 `+1` 只影响本地构建。

### 4.2 本地验证（强烈建议）

```powershell
flutter analyze
flutter test
flutter build apk --release
```

产物 `build/app/outputs/flutter-apk/app-release.apk`。

校验签名：

```powershell
$apksigner = Get-ChildItem "$env:ANDROID_HOME\build-tools" -Directory |
  Sort-Object Name -Descending | Select-Object -First 1
& "$($apksigner.FullName)\apksigner.bat" verify --print-certs `
  build\app\outputs\flutter-apk\app-release.apk
```

**必须**看到你的证书指纹（`CN=...`），不能是 `CN=Android Debug`。

### 4.3 打 tag 触发 CI

```bash
git add -A
git commit -m "release: v0.1.0"
git tag v0.1.0
git push origin main --tags
```

CI 会自动：
1. `flutter analyze` + `flutter test`
2. 从 Secrets 还原 keystore
3. `flutter build apk --release`
4. `apksigner verify`（debug 签名直接失败，阻止误发）
5. 创建 GitHub Release，附 `yunying-vod-v0.1.0.apk` 与 `.sha256`

### 4.4 验证 Release

打开 `https://github.com/striferxu/YunYingVOD/releases`，确认：
- 有对应 tag 的 Release
- 附件里有 `.apk` 和 `.apk.sha256`
- Release Notes 里的已知限制正确

---

## 5. 版本号规则

| 位 | 含义 | 什么时候加 |
|---|---|---|
| major（第 1 位） | 不兼容变更 | 极少 |
| minor（第 2 位） | 新功能 | 每个阶段（P4→P5 等） |
| patch（第 3 位） | 修 bug | 每次修复 |

versionCode **必须单调递增**，否则 Android 拒绝覆盖安装。

---

## 6. 排查

| 现象 | 原因 | 处理 |
|---|---|---|
| CI 报 `KEYSTORE_BASE64 secret 未配置` | Secret 没加 | 按第 3 节补齐 4 个 |
| CI 报 `APK 使用了 debug 签名，拒绝发布` | `key.properties` 没生成成功 | 检查 Secrets 名是否拼错（区分大小写） |
| CI 报 `Failed to read key from keystore` | 口令或 alias 错 | 本地用 `keytool -list` 复核 |
| 用户装不上（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`） | 签名不一致（换了 keystore） | 只能卸载重装；说明 keystore 丢失了 |
| 用户装不上（`INSTALL_FAILED_VERSION_DOWNGRADE`） | versionCode 没递增 | 改 `pubspec.yaml` 的 `+N` 或重新打 tag |

---

## 7. 安全自查（每次发版前）

```bash
# 仓库里不应出现任何密钥文件
git ls-files | grep -Ei '\.(jks|keystore)$|key\.properties' && echo "❌ 有密钥入库！"

# 历史提交里也不应有
git log -p --all | grep -Ei 'storePassword|keyPassword' | head
```

两条都应无输出。

---

## 8. 已知限制（写进 Release Notes）

1. 蜂窝网络上传大文件（>300 秒）可能被服务端超时中断 —— 仅建议 WiFi 上传
2. 转码服务器单并发，多人同时上传需排队
3. admin 管理功能（用户审核 / 视频管理）请使用 Web 端
4. App 长效 token 有效期 30 天，改密码后所有设备需重新登录
