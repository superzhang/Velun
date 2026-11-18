# Velun

简体中文 · [English](README.en.md)

**为 Mac 打造的私人影音播放器。** Velun 的海报墙、剧集详情和播放操作受到 Infuse 启发。如果你喜欢 Infuse 的浏览和续播体验，想用一款开源的 macOS 应用管理本地或 NAS 片库，可以试试 Velun。这是独立项目，与 Infuse 和 Firecore 无关联。

## 功能

- **本地与 NAS 片库** · 添加本地文件夹、SMB、WebDAV 或 Alist，也支持连接 Jellyfin、Emby 和 Plex。
- **海报墙与剧集** · 查看海报和演职员信息、收藏、按季选集、保存观看进度和续播。
- **多格式播放** · 使用 AVFoundation 和 libmpv，支持 MKV、音轨与字幕选择、HDR10 / HLG，以及兼容片源的 AirPlay。

## 下载与构建

打开 [GitHub Releases](https://github.com/superzhang/Velun/releases)，查看相应版本的下载内容和系统要求。目前的构建面向 Apple Silicon，应用包最低要求 macOS 27.2。

从源码运行需要 Xcode 和 Homebrew：

```sh
brew install mpv ffmpeg rclone
swift run
swift test
```

要生成应用包，安装有效的 Apple 代码签名证书，再运行 `./scripts/build-app.sh`。如有多张证书，可用 `LUMA_SIGNING_IDENTITY` 指定。应用包生成在上一级目录，名为 `Velun.app`。

## 配置 TMDB 海报

播放视频无需 TMDB。要自动匹配海报和影片信息，请用自己的 TMDB 账户申请凭据。项目和发布包均不提供预置凭据。

1. 登录 TMDB，在 [账户的 API 设置](https://www.themoviedb.org/settings/api) 申请 API 凭据。
2. 复制 **API Read Access Token（读取访问令牌）**。Velun 的输入框接受这个令牌。
3. 在 Velun 打开 **偏好设置 → TMDB → 海报与影片信息 → 读取访问令牌**，粘贴后点击 **保存令牌**。随后可开启自动匹配，或点击「为未匹配视频查找海报」。

令牌仅存入本机 macOS 钥匙串。申请与认证说明见 [TMDB 官方文档](https://developer.themoviedb.org/docs/authentication-application)。

## 许可证

Velun 源码采用 [GPL-3.0-or-later](LICENSE)。依赖、TMDB 数据和图标的来源与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。
