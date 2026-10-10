# Changelog

All notable changes to this project will be documented in this file.

Format: Each version section starts with `## x.x.x`, followed by change lines starting with `-`.

---

## Unreleased（本 fork 本地定制）

- feat: 关注列表 / 直播间显示主播开播时长
  - 关注设置 →「时长显示」可切换：开播时长（默认）/ 观看时长
  - 开播时长模式：关注列表显示「开播了X小时Y分钟」，直播间内显示每秒刷新的 HH:mm:ss 计时
  - 数据复用刷新时的房间详情，零额外请求（B站/斗鱼/虎牙；抖音走 reflow 接口）
- feat: 音量均衡（Windows）：EBU R128 loudnorm 音频滤镜，需配合自建 libmpv
- feat: 音量均衡（Android）：自建 libmpv 启用 loudnorm 滤镜
  - 构建编排：`.github/workflows/build-libmpv-android-custom.yml`，产物发布到 Release `libmpv-android-custom-v1`
  - 内嵌 `simple_live_app/packages/media_kit_libs_android_video`（仅替换 Android libmpv 下载源 + SHA 校验）
- feat: 窗口全屏 / 自定义画面尺寸 / 右侧消息面板拖拽 / Windows 竖滑调音量（早前本地定制）
- feat: 斗鱼网页接口优先（全清晰度档位）+ 应用内网页登录（账号密码/手机验证码）
- chore: 同步上游 media_kit 到 native-assets 架构 + Flutter 3.47.6
  - media_kit 改为**内嵌** `simple_live_app/packages/media_kit`（与上游 SlotSun/media-kit 同源），仅定制 `hook/native_bundles.json`：Android×4 + Windows x64 指向自建含 loudnorm 的 libmpv（音量均衡）
  - 移除全部 `media_kit_libs_*` 依赖/覆盖与两个旧内嵌包；`media_kit_video` 改为直接引用上游 SlotSun/media-kit
  - `flatpak/flatpak-manifest.yaml` / `.fvmrc` 同步至 Flutter 3.47.6（修复 flatpak 构建）
- fix: `get` 依赖改钉固定 commit（原 `ref: master` 导致 `pubspec.lock` 不可重现）
- test: 清理 Flutter 模板残留的无效计数器测试，改为真实冒烟测试

## 1.8.14

- fix: 进一步修正douyu断流问题
- tips: ios和macos用户请到action更新测试或者下载上游仓库版本

## 1.8.13

- feat: 支持自定义数据目录 (data_hive_ce) #174
- fix: douyu, 需要在配置douyu参数 说明 #182
- fix: 统一关注业务逻辑，修复tag数据混乱 #178
- fix: Windows屏幕亮度重置问题 #180
- 一些数据错误和潜在问题的修复
- 一些细节调整
- 关于linux的一系列修复 @pugaizai
- tips: ios和macos用户请到action更新测试或者下载上游仓库版本

## 1.8.12

- 基于v10811的热修版本：aur 以及 部分ui修复 #173
- feat: 允许按tag排序
- feat: 自由画面尺寸功能 #156
- feat: windows NVIDIA RTX VSR @ZhaiXB
- feat: 房间专属屏蔽词和屏蔽用户
- feat: PC端小窗记忆/开屏最大化
- feat: 弹幕随屏幕尺寸放缩
- feat: 允许禁用滑动调节亮度/音量
- feat: pc端参数启动应用
- fix: huya弹幕完整性
- 一些数据错误和潜在问题的修复
- 一些细节调整
- 关于linux的一系列修复 @pugaizai
- tips: ios和macos用户请到action更新测试或者下载上游仓库版本
