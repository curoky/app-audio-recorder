# 本地代码签名证书

`task app:bundle` 默认用本地自签名证书 `App Audio Recorder Dev` 给 `.app` 签名
（见 [Taskfile.yml](../Taskfile.yml) 的 `SIGN_IDENTITY` 默认值）。本文档说明为什么需要这张
证书，以及如何一次性创建并信任它。

## 为什么需要稳定证书

macOS 的隐私数据库（TCC）按签名的 *designated requirement* 识别 App：

- **Ad-hoc 签名**（`codesign --sign -`）锁的是二进制 `cdhash`。每次重新编译哈希都变，
  TCC 把它当成一个全新 App，已授权的屏幕录制 / 麦克风权限随之作废，必须重新授权。
- **稳定证书签名**锁的是 `identifier + 证书`。只要 bundle ID（`com.local.AppAudioRecorder`）
  和证书不变，重编多少次 `cdhash` 都无所谓，一次授权长期保留。

因此开发期用一张固定的本地证书签名，避免每次重编都要去系统设置重新开权限。
无需 Apple 开发者账号，自签名的 Code Signing 证书即可。

## 一次性创建流程

### 1. 用钥匙串助理创建证书

1. 打开**钥匙串访问**（Keychain Access）。
2. 菜单栏 → **钥匙串访问 → 证书助理 → 创建证书…**
   （Certificate Assistant → Create a Certificate…）。
3. 填写：

   | 字段 | 值 |
   | --- | --- |
   | 名称（Name） | `App Audio Recorder Dev` ← 必须逐字一致，Taskfile 引用此名 |
   | 身份类型（Identity Type） | 自签名根证书（Self-Signed Root） |
   | 证书类型（Certificate Type） | **代码签名（Code Signing）** ← 默认是 SSL，务必改 |

4. **不要**勾「让我覆盖这些默认值（Let me override defaults）」。
5. 点**创建 → 继续 → 完成**。证书进入「登录」钥匙串。

> ⚠️ **只创建一张。** 同名证书创建多张会导致 `codesign` 报 `ambiguous`，反而回退到
> 系统 Apple 签名。若不小心建了多张，见下方「清理重复证书」。

### 2. 设为受信任的代码签名证书

自签名根证书默认不受信任，不做这步 `find-identity -v` 会显示 `0 valid identities`。

1. 钥匙串访问左侧选「登录」钥匙串 →「我的证书」，双击 `App Audio Recorder Dev`。
2. 展开顶部「**信任（Trust）**」。
3. 把「**代码签名（Code Signing）**」设为「**始终信任（Always Trust）**」。
4. 关闭窗口，输入登录密码确认。

### 3. 验证证书就位

```bash
security find-identity -v -p codesigning
```

应出现且仅出现一行有效身份：

```text
1) <HASH> "App Audio Recorder Dev"
   1 valid identities found
```

### 4. 打包并确认签名生效

```bash
task app:bundle
```

首次用新证书签名时，钥匙串可能弹「codesign 想使用私钥」授权框，点**始终允许**
（Always Allow），之后重编不再弹。确认产物签名身份：

```bash
codesign -dvv ".build/release/App Audio Recorder.app" 2>&1 | grep -iE "authority|identifier"
```

预期：

```text
Identifier=com.local.AppAudioRecorder
Authority=App Audio Recorder Dev
```

`Authority` 是 `App Audio Recorder Dev`（而非 `adhoc`）即成功。

### 5. 授权一次系统权限

签名身份变化后 TCC 视为新 App，需重新授权一次（**仅此一次**，之后重编都认得）。
可先清掉旧的 ad-hoc 授权残留：

```bash
tccutil reset ScreenCapture com.local.AppAudioRecorder
tccutil reset Microphone com.local.AppAudioRecorder
```

然后 `task app:run` 打开 App、触发一次录制，在系统弹窗或
**系统设置 → 隐私与安全性 → 屏幕录制 / 麦克风**里授权。

## 注意事项

- **证书别删、别重建。** 删除或重新创建（即使同名）都会生成新身份，TCC 会当成新 App
  再次重置权限。这张证书创建一次长期复用。
- 临时需要 ad-hoc 打包（如给别的机器）：`task app:bundle SIGN_IDENTITY=-`。
- 换用 Apple Development 证书：`task app:bundle SIGN_IDENTITY="Apple Development: ..."`。
- CI（[.github/workflows/ci.yml](../.github/workflows/ci.yml)）不走 Taskfile，用内联 ad-hoc
  签名，与本地证书互不影响。

## 清理重复证书

若 `find-identity` 出现多张同名证书，或 `codesign` 报 `ambiguous`，先用 SHA-1 哈希逐张删除
（`delete-certificate` 会连带删除配对私钥，需登录密码授权）：

```bash
# 列出所有同名身份及其哈希
security find-identity -p codesigning login.keychain-db

# 按哈希删除多余的（保留想留下的那一张，或全删后重建一张）
security delete-certificate -Z <SHA-1_HASH> login.keychain-db
```

删除后回到「创建流程」重新建一张并设信任。
