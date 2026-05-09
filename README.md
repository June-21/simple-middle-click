# Simple Middle Click

Simple Middle Click is a small macOS menu bar utility that maps a three-finger tap on the trackpad to a mouse middle click.

中文：Simple Middle Click 是一个 macOS 菜单栏小工具，用三指轻触触控板触发鼠标中键点击。

## Features

- Three-finger tap triggers a middle mouse click.
- Runs as a menu bar app without a Dock icon.
- Minimal settings window.
- In-app language selection: English, Simplified Chinese, Japanese.
- Optional launch at login.
- Accessibility permission guidance on first launch.

中文：

- 三指轻触触发鼠标中键。
- 作为菜单栏应用运行，不显示 Dock 图标。
- 设置页保持轻量。
- 支持英文、简体中文、日文。
- 支持开机自启。
- 首次启动会引导开启辅助功能权限。

## Requirements

- macOS only.
- Trackpad with multitouch support.
- Accessibility permission is required for posting mouse events.

中文：仅支持 macOS，需要支持多点触控的触控板，并需要开启辅助功能权限。

## Permissions

The app needs Accessibility permission to post a middle mouse click event. If permission is missing, the app shows a prompt and can open System Settings for you.

After permission is granted, the app watches for the authorization state and restarts itself automatically.

中文：应用需要辅助功能权限才能发送鼠标中键事件。授权成功后，应用会检测状态并自动重启。

## Settings

Open the menu bar icon and choose **Settings**.

Available settings:

- **Language**: English, Simplified Chinese, Japanese.
- **Launch at login**: register or unregister the app as a macOS login item.

中文：点击菜单栏图标进入设置，可切换语言并设置开机自启。

## Build And Run

Open the project in Xcode and run the `simple-middle-click` target.

The app is configured as an accessory app, so it does not appear in the Dock. Look for its icon in the menu bar.

中文：在 Xcode 中运行 `simple-middle-click` target。应用不会显示在 Dock，请查看菜单栏图标。

## Technical Notes

macOS public APIs do not expose a reliable global three-finger tap event. This project dynamically loads the private `MultitouchSupport.framework` to read raw multitouch frames, then posts a Quartz middle mouse click using `CGEvent`.

Because it uses a private framework, this project is intended for local/personal use and is not suitable for Mac App Store distribution.

中文：macOS 公共 API 不能可靠获取全局三指轻触事件，因此项目动态加载私有 `MultitouchSupport.framework`。这适合本机自用，不适合上架 Mac App Store。

## Troubleshooting

If three-finger tap is detected but middle click does not work, check Accessibility permission for the exact app bundle path printed in the Xcode console.

If System Settings shows an old or duplicated app entry, remove it from Accessibility and add the current build again.

中文：如果检测到三指轻触但中键不生效，请确认辅助功能里授权的是当前运行的 app 路径，而不是旧 build。
