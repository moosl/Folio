# Folio

Folio 是一个使用 Swift 和 AppKit 编写的 macOS 本地编辑器。可以把代码仓库、笔记目录和素材文件夹一起拖进窗口，跨项目搜索文件，也可以一边写 Markdown，一边看排版结果。

![Folio 浅色模式下的 Markdown 源码与实时预览](docs/screenshots/markdown.png)

## 安装与更新

从 [GitHub Releases](https://github.com/moosl/Folio/releases/latest) 下载正式 ZIP，解压后将 Folio.app 拖到「应用程序」。当前发布包适用于 **Apple Silicon、macOS 13 或更高版本**。同一个包适配经典和新版 macOS 图标。

从 **0.2.0** 起，可以在 **Folio → 检查更新…** 中检查、下载并安装新版。更新由 Sparkle 验签，正式应用使用 Apple Developer ID 签名，并经过公证。更早的版本需要手动安装一次 0.2.0 或更高版本。

## 使用

- **浏览项目** — 单击文件进入临时预览，双击或开始编辑会固定标签。右键文件夹可以新建文件、创建子文件夹或复制路径。重新启动后会恢复项目、标签顺序和当前文件。
- **查找与编辑** — 快速打开支持模糊匹配。项目全文搜索遵守忽略规则，也会搜索已打开文件中的未保存修改。打开匹配项会跳到对应行。
- **写 Markdown** — 在源码、分栏和预览之间切换。支持 YAML 元数据、表格、任务列表、代码块和本地图片。
- **跟随磁盘变化** — 外部程序修改文件后，干净的标签会自动刷新。有未保存编辑时保留草稿，可以比较两个版本再决定如何处理。
- **查看素材** — 在标签页中查看图片、播放 MP3，或把 HTML 交给默认浏览器。

| 项目概览 | 深色代码编辑器 |
| --- | --- |
| ![文件夹卡片、文件列表与项目树](docs/screenshots/workspace.png) | ![深色模式下编辑 Swift 文件](docs/screenshots/editor.png) |

### 常用快捷键

| 快捷键 | 操作 |
| --- | --- |
| ⌘N | 新建文件 |
| ⌘O / ⇧⌘O | 打开文件 / 添加项目文件夹 |
| ⌘P / ⇧⌘F | 快速打开 / 跨项目全文搜索 |
| ⌘F / ⌥⌘H | 当前文件查找 / 替换 |
| ⌘S / ⇧⌘S | 保存 / 另存为 |
| ⌘E | 切换 Markdown 源码与预览 |
| ⌘+ / ⌘− | 调整当前标签字号 |
| ⌘1 / ⌘W | 返回项目概览 / 关闭标签 |

## 从源码构建

需要 macOS 和 Xcode Command Line Tools。首次构建会下载并校验固定版本的 cmark-gfm、libyaml、ripgrep 和 Sparkle。脚本为当前 Mac 架构生成应用。

```sh
git clone https://github.com/moosl/Folio.git
cd Folio
bash scripts/build.sh
open dist/Folio.app
```

在已登录的 macOS 图形会话中运行 `bash scripts/test.sh`。测试会在临时目录打开真实窗口，覆盖编辑、预览、搜索、文件监听、会话恢复和源码文件显示。性能数据和复现命令见 [性能报告](PERFORMANCE.md)。

## 发布新版本

发布 Mac 需要 Apple Silicon、Xcode Command Line Tools、已登录的 `gh` 和 `asc`、OpenSSL 3+、Developer ID Application 证书和 Sparkle 钥匙串账户 `moosl.Folio.updates`。在该用户的图形登录会话中运行一次：

```sh
bash scripts/install-tag-publisher.sh
```

之后把改动推到 `main`，再推送稳定版本 tag 即可。以 `v0.2.1` 为例：

```sh
git tag -a v0.2.1 -m 'Folio 0.2.1'
git push origin v0.2.1
```

本机 LaunchAgent 每五分钟检查一次远端，高于当前 Latest 的 `v主.次.补丁` 标签会按版本顺序处理。只构建已进入远端 `main` 历史的提交。正式包的版本取自 tag，内部构建号在上一份已签名更新清单的基础上递增。发布机睡眠或离线时会在恢复后补发，签名时需能访问登录钥匙串。

发布程序在独立检出目录构建，签名、公证、装订票据，再用普通 ZIP 解压器解包并验证 Gatekeeper。ZIP 与已签名的 `appcast.xml` 在同一 Release 草稿中上传，远端摘要核对成功后一起设为 Latest。中断会在下轮重试；已完成的正式包可复用。私钥留在本机。

查看状态：`launchctl print "gui/$(id -u)/local.folio.tag-publisher"`。发布日志位于 `~/Library/Application Support/FolioRelease/publisher.log`，每个版本的构建日志位于该目录下的 `jobs/<tag>/build.log`。更新发布程序后重新运行安装脚本。

本项目的 Sparkle 公钥和更新地址在 `app/Info.plist`。分发自己的 fork 时，请换用自己的更新地址、公钥、签名密钥账户及发布仓库。私钥保存在发布者的钥匙串中。

## 许可证

Folio 使用 [MIT License](LICENSE)。cmark-gfm、libyaml、ripgrep 和 Sparkle 各自的许可声明随构建产物附带。
