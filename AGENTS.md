# Folio 项目约定

## 开发与提交

- 修改前先读相关实现，优先局部编辑。禁止执行 `rm -rf`。
- 在仓库根目录运行 `bash scripts/build.sh` 构建本机架构的 `dist/Folio.app`。修改应用代码后，在已登录的 macOS 图形会话中运行 `bash scripts/test.sh`，覆盖真实窗口、退出重开和源码文件显示。
- 公开仓库使用 MIT 许可证。提交前用 `git diff --cached --name-only` 检查文件清单，并运行 `git diff --cached --check`。保留构建所需的最终图标、图标目录和 README 实拍截图。按 `.gitignore` 排除图标草稿、缓存、发行包和凭据。

## 推送 tag 发布

1. 用户要求发布时，先确认目标提交已通过测试并推到 `origin/main`。普通代码或文档提交无需打 tag。
2. 确认稳定 tag 符合 `vX.Y.Z`、尚未使用，且版本高于 GitHub Latest。在目标提交上创建并推送这个 tag：

   ```sh
   # tag 为此次要发布的版本，commit 为已测试的提交 SHA
   git tag -a "$tag" "$commit" -m "Folio ${tag#v}"
   git push origin "refs/tags/$tag"
   ```

3. 本机 LaunchAgent 每五分钟检查远端，按版本顺序处理已进入 `origin/main` 历史的 tag。发布 Mac 需要在线且能访问登录钥匙串。正式包版本取自 tag，内部构建号取上一份验签通过的更新清单加一，无需手改 `Info.plist`。
4. 跟踪任务直到 GitHub Release 和公开更新清单都已验证。同一 tag 由发布服务处理，避免并行手动发布或移动 tag。

## 签名、公证与 Sparkle 更新

- `scripts/tag-release.py` 在独立检出目录调用 `scripts/release.sh`。发布脚本先签 Sparkle 的嵌套组件、框架和 ripgrep，再签应用，使用 Developer ID、Hardened Runtime 和时间戳。Apple 公证通过后，将票据装订到应用并验证。
- 正式 ZIP 使用 `ditto -c -k --norsrc --noextattr --noacl --keepParent`，保留框架符号链接，排除 AppleDouble 文件。运行 `bash scripts/verify-release-zip.sh "$archive"`，用普通 `unzip` 解压，给副本加下载隔离标记，再检查文件权限、代码签名、公证票据和 Gatekeeper。
- Sparkle 使用钥匙串账户 `moosl.Folio.updates` 签署更新。发布程序用应用内置公钥核验 ZIP 和 `appcast.xml`，将两者上传到同一个 Release 草稿，核对远端 SHA-256 后再一起设为 Latest。保持更新入口 `https://github.com/moosl/Folio/releases/latest/download/appcast.xml` 稳定。
- 发布后用 `gh release view "$tag" --repo moosl/Folio --json isDraft,assets,url` 核对产物，从公开入口重新下载清单和 ZIP，核对版本、签名及摘要，并对下载件再运行 ZIP 验证脚本。改动更新流程时，用独立的旧版副本实测升级，核对安装后的构建号和 Gatekeeper 结果。

## 本机发布服务与故障排查

- 首次配置或修改发布程序后，在发布 Mac 的图形登录会话运行 `bash scripts/install-tag-publisher.sh`。需要 Apple Silicon、Xcode Command Line Tools、已登录的 `gh` 和 `asc`、OpenSSL 3+ 及签名钥匙串。私钥留在本机。若系统请求钥匙串授权，请用户核对工具和账户后在系统窗口操作。
- 查看任务状态及日志：

   ```sh
   launchctl print "gui/$(id -u)/local.folio.tag-publisher"
   logs="$HOME/Library/Application Support/FolioRelease"
   tail -n 30 "$logs/publisher.log"
   tail -n 30 "$logs/jobs/$tag/build.log"
   ```

- 任务中断时先看日志。服务会在下轮重试，并可从已核验的公证 ZIP 继续生成清单。若只需立即检查一次，运行 `launchctl kickstart "gui/$(id -u)/local.folio.tag-publisher"`。
- 遇到“Apple 无法验证 Folio”，分别核验公开下载件和实际安装的 `.app`。0.2.0 曾因解压后 `Sparkle.framework` 内多出 `._*` 文件而被拒绝，即使公证票据有效。让用户从 Releases 下载修复版并在访达中替换应用；保留 Gatekeeper 和下载隔离保护。
