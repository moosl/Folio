# Mac App Store 渠道

运行 `bash scripts/build.sh --store` 可生成供本机验证的 `.build/app-store/Folio.app`。此目标启用 App Sandbox 和用户选中文件的读写权限，使用安全范围书签恢复会话。随应用提供的 ripgrep 继承沙盒。商店包不链接 Sparkle，也不显示站外更新菜单。

取得商店所需分发证书后，可通过环境变量 `FOLIO_STORE_APP_IDENTITY` 指定应用签名身份。用于上传的安装包另需 Mac Installer Distribution 身份：

```sh
bash scripts/build.sh --store
productbuild --component .build/app-store/Folio.app /Applications \
  --sign "$FOLIO_STORE_INSTALLER_IDENTITY" .build/app-store/Folio.pkg
pkgutil --check-signature .build/app-store/Folio.pkg
```

创建 App Store Connect 的 macOS 应用记录后，使用其数字 ID 上传。上传、苹果处理构建、提交审核是三个独立步骤。

```sh
app=.build/app-store/Folio.app/Contents/Info.plist
asc builds upload --app "$FOLIO_ASC_APP_ID" --pkg .build/app-store/Folio.pkg \
  --version "$(plutil -extract CFBundleShortVersionString raw "$app")" \
  --build-number "$(plutil -extract CFBundleVersion raw "$app")" --wait
```

正式提交前确认商店名、价格、地区、年龄分级、隐私披露和审核联系方式，并检查隐私政策 URL 可公开打开。此渠道独立于 GitHub tag 发布服务。
