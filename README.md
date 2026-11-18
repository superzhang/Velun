# Velun

Velun 是 macOS 原生私人影音播放器，用于整理和播放你自己的电影与剧集。

- 从本地文件夹、SMB、WebDAV 或 Alist 添加片源。也可接入 Jellyfin、Emby 和 Plex。
- 使用自己的 TMDB 读取访问令牌匹配海报、简介和演职员信息；支持手动修正匹配。
- 按季浏览剧集、保存观看进度、管理收藏，支持播放中选集。
- 使用 AVFoundation 播放兼容片源，并通过 libmpv 支持 MKV 等更多格式、音轨和字幕。
- 支持 HDR10 / HLG，并根据显示设备决定输出或转换为 SDR。兼容的视频可通过系统播放器使用 AirPlay。

## 从源码运行

需要 Apple Silicon、Xcode 和 Homebrew。随 Homebrew 安装的播放器库可能要求更高版本的 macOS；当前打包配置的最低版本为 macOS 27.2。

```sh
brew install mpv ffmpeg rclone
swift run
swift test
```

如需生成 macOS 应用包，安装有效的 Apple 代码签名证书，再运行 `./scripts/build-app.sh`。如果钥匙串中有多张签名证书，通过 `LUMA_SIGNING_IDENTITY` 指定使用哪一张。构建产物为上一级目录的 `Velun.app`。

## 添加片源与海报

在应用的「偏好设置 → 添加或管理来源」中添加本地文件夹或网络共享。要启用海报匹配，在「偏好设置 → TMDB → 海报与影片信息」填写你自己的 TMDB 读取访问令牌。令牌保存在 macOS 钥匙串中。

Velun 沿用早期版本的本机片库路径 `~/Library/Application Support/Luma`。

## 第三方组件与数据

第三方组件、TMDB 数据和图标的来源及许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 许可证

Velun 源码采用 [GNU 通用公共许可证第 3 版或任何更新版本](LICENSE)（`GPL-3.0-or-later`）。第三方组件及素材适用各自的许可证，详见 [THIRD_PARTY.md](THIRD_PARTY.md)。
