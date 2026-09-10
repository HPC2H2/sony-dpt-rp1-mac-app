# DigitalPaper.app Repair Script / DigitalPaper.app 修复脚本

## 中文说明

### 用途

`scripts/release.sh` 用于修复一个已经存在的 `DigitalPaper.app`，不负责编译源码，也不依赖 Xcode、XcodeGen 或 `xcodebuild`。

它解决的主要问题是：应用外层签名与内嵌的 `DigitalPaperKit.framework` 签名不一致，导致 macOS 在启动阶段由 dyld 拒绝加载应用。

脚本执行顺序如下：

1. 先签名 `Contents/Frameworks` 下的动态库和 Framework；
2. 再签名外层 `DigitalPaper.app`；
3. 验证嵌套代码和 App 签名；
4. 生成修复后的 ZIP；
5. 默认打开修复后的 App。

### 使用方法

```bash
cd /path/to/sony-dpt-rp1-mac-app
scripts/release.sh /path/to/DigitalPaper.app
```

例如：

```bash
scripts/release.sh \
  /Users/hpc2h2/Downloads/DigitalPaper-original/DigitalPaper.app
```

修复后的 ZIP 默认生成在 App 所在目录的 `dist/` 文件夹中：

```text
dist/DigitalPaper-repaired.zip
```

### 签名模式

默认使用 macOS Ad-hoc 签名，适合本机修复和测试：

```bash
scripts/release.sh /path/to/DigitalPaper.app
```

如果本机有 Developer ID Application 证书，可以指定签名身份：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  scripts/release.sh /path/to/DigitalPaper.app
```

可选环境变量：

| 变量 | 作用 |
|---|---|
| `SIGN_IDENTITY` | 签名身份，默认是 `-`，即 Ad-hoc 签名 |
| `OPEN_AFTER_SIGNING` | 设置为 `0` 时，修复后不自动打开 App |
| `DIST` | 自定义 ZIP 输出目录 |
| `ZIP_NAME` | 自定义 ZIP 文件名 |
| `APP_ENTITLEMENTS` | 自定义外层 App 的 entitlements 文件 |

### 注意事项

- 脚本会原地修改传入的 `.app`，如需保留原文件请先复制一份。
- Ad-hoc 签名不等于 Developer ID 签名，其他 Mac 可能仍显示 Gatekeeper 警告。
- 该脚本不执行 Apple notarization；正式对外发布仍需 Developer ID 签名和公证流程。
- `.app` 必须已经存在。它可以来自 GitHub Release ZIP，也可以来自其他构建流程。

## English

### Purpose

`scripts/release.sh` repairs an existing `DigitalPaper.app`. It does not compile the source project and does not require Xcode, XcodeGen, or `xcodebuild`.

It fixes the common launch failure where the outer application and the embedded `DigitalPaperKit.framework` have incompatible code signatures, causing macOS dyld to reject the app before launch.

The script:

1. Signs embedded libraries and frameworks first;
2. Signs the outer `DigitalPaper.app` second;
3. Verifies the nested code and the app bundle;
4. Creates a repaired ZIP archive;
5. Opens the repaired app by default.

### Usage

```bash
cd /path/to/sony-dpt-rp1-mac-app
scripts/release.sh /path/to/DigitalPaper.app
```

Example:

```bash
scripts/release.sh \
  /Users/hpc2h2/Downloads/DigitalPaper-original/DigitalPaper.app
```

The repaired archive is written to the `dist/` directory next to the app by default:

```text
dist/DigitalPaper-repaired.zip
```

### Signing modes

The default is ad-hoc signing for local repair and testing:

```bash
scripts/release.sh /path/to/DigitalPaper.app
```

To use a Developer ID Application certificate:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  scripts/release.sh /path/to/DigitalPaper.app
```

Optional environment variables:

| Variable | Description |
|---|---|
| `SIGN_IDENTITY` | Signing identity; defaults to `-` for ad-hoc signing |
| `OPEN_AFTER_SIGNING` | Set to `0` to avoid opening the repaired app |
| `DIST` | Custom output directory for the ZIP |
| `ZIP_NAME` | Custom ZIP filename |
| `APP_ENTITLEMENTS` | Custom entitlements file for the outer app |

### Notes

- The input `.app` is modified in place. Make a copy first if the original must be preserved.
- Ad-hoc signing is not Developer ID signing; Gatekeeper may still warn on another Mac.
- This script does not perform Apple notarization. A public release still requires Developer ID signing and notarization.
- The input `.app` must already exist. It may come from a GitHub Release ZIP or another build process.
