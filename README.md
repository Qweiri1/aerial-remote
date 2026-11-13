# 遥控器 · 原生壳（iOS）

网页版（`remote/page.html`）在 iOS 上有两个死结，网页层永远解不掉：

1. **电视上点输入框，手机不会自动弹键盘** —— Safari 只允许在「真实手指触摸」的事件栈里
   拉起键盘，电视那边发来的请求属于网络事件，`input.focus()` 被静默丢弃。
2. **输入框上方那条 `^ v ✓` 栏** —— iOS 给网页表单加的 Form Assistant，
   网页没有 API 能关。

原生壳把这两件事都解决了，遥控器的界面仍然是同一张网页：

- `UIImage`/`WKWebView` 全屏加载 `http://<电脑>:8899/?native=1`
- 网页里那套浮层输入条被 `?native=1` 关掉（`page.html` 开头有判断）
- 原生每 0.55s 问一次 `/api/ime`，电视一有输入框聚焦就立刻
  `becomeFirstResponder()` —— **输入框和键盘同时出现，不需要在手机上补点**
- 输入条是浮在 webView 上的独立视图，键盘弹起只抬高它自己，
  webView 尺寸不变 → **下面的遥控器 UI 一个像素都不动**
- `RemoteTextField.inputAccessoryView = nil` → **没有 `^ v ✓` 那条栏**
- 打字 0.3s 防抖后整段 POST 到 `/api/text`（`replace:true`，电视上退格也能删）
- 回车 = 发送（带 enter），发完清空

## 编译（需要 macOS + Xcode）

```bash
brew install xcodegen
xcodegen generate
open AerialRemote.xcodeproj
# Xcode 里选自己的开发者证书 → Run 进手机
```

命令行出未签名 ipa：

```bash
xcodebuild -project AerialRemote.xcodeproj -scheme AerialRemote \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/AerialRemote.app Payload/
zip -qr AerialRemote-unsigned.ipa Payload
```

## 没有 Mac：用 GitHub Actions 云编译

`.github/workflows/build-ipa.yml` 已经写好。把这个目录当仓库根目录推上去：

```bash
git init && git add . && git commit -m "AerialRemote"
git remote add origin <你的仓库>
git push -u origin main
```

Actions 会自动跑 `build-ipa`，跑完进 Artifacts 下载 `AerialRemote-unsigned.ipa`，
然后用 Sideloadly / AltStore / TrollStore 之类拿你自己的证书签装。

## 用法

- 首次启动若连不上，中间会出现「更改服务器地址」按钮；也可以**两指长按画面 1.2 秒**改地址
- 默认地址 `http://aerial.local:8899/`（电脑上 `mdns_name.py` 在广播这个主机名）；
  换 Wi-Fi 段或 mDNS 不生效时，直接填 `192.168.x.x:8899`
- 首次连接会弹「允许访问本地网络」，必须点允许，否则连不上电视

## 文件

| 文件 | 作用 |
| --- | --- |
| `app/main.swift` | 显式入口 |
| `app/AppDelegate.swift` | 建窗口 |
| `app/RemoteViewController.swift` | webView + 原生输入条 + 键盘跟随 + 轮询同步 |
| `app/RemoteTextField.swift` | 干掉 `inputAccessoryView` 的输入框 |
| `project.yml` | XcodeGen 工程描述（不用手改 pbxproj） |
