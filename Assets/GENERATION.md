# Luma 图标

当前版本采用 Apple Icon Composer 原生图标：`Luma.icon`。白色背景，前景为 `Play.svg` 中的简约橙色播放符号。

`build-app.sh` 使用 Xcode actool 编译 Assets.car、Luma.icns 和图标 Info.plist 元数据。由 Apple 工具生成系统蒙版、边距与多尺寸回退图标，不再运行时设置 NSApplication.applicationIconImage。

`Luma.icns` 是原生编译产物的副本。`Luma-icon.png` 是早期 image_gen 设计参考，保留来源记录，不用于当前应用打包。Icon Composer 图层不预先裁切蒙版，系统负责最终形状。
