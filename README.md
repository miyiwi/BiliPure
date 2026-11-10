# BiliPure

一个轻量的第三方哔哩哔哩客户端，主要面向 iOS。

> 非官方项目，仅用于学习 Flutter 与音视频开发。请勿用于商业用途。

## 功能

- **首页推荐**：双列瀑布流，下拉刷新 / 上拉加载
- **热门**：按热度浏览全站热门视频
- **播放**：AVPlayer 内核（`video_player`），支持进度拖动、清晰度切换
- **弹幕**：完整解析 bilibili 弹幕 XML（滚动 / 顶部 / 底部），自研渲染层，跟随播放进度精确同步
- **分 P**：多 P 视频可切换
- **扫码登录**：二维码登录，Cookie 本地持久化
- **相关推荐**：播放页底部推荐流

## 目录结构

```
lib/
├── api/bili_api.dart          # 业务接口封装
├── core/
│   ├── http.dart              # Dio 客户端 + Cookie 罐 + 信封解包
│   ├── wbi.dart               # WBI 签名算法
│   └── format.dart            # 播放量 / 时长 / 相对时间格式化
├── models/                    # FeedItem / VideoDetail / PlayInfo / Danmaku
├── pages/
│   ├── home/                  # 推荐流
│   ├── popular/               # 热门
│   ├── video/                 # 播放页
│   └── mine/                  # 我的 + 扫码登录
├── services/danmaku_service.dart
├── widgets/
│   ├── danmaku_overlay.dart   # 弹幕渲染引擎
│   ├── video_card.dart
│   └── error_view.dart
└── main.dart
```

## 技术要点

### WBI 签名

bilibili 的 web 接口会对参数签名，否则返回 `-352`。实现见 `lib/core/wbi.dart`：

1. 拉 `/x/web-interface/nav`，取 `wbi_img.img_url` / `sub_url` 的文件名部分作为 `imgKey` / `subKey`
2. 用固定混排表重排 `imgKey + subKey`，截取 32 位得到 `mixinKey`
3. 参数追加 `wts` 后按 key 升序拼接，`w_rid = md5(query + mixinKey)`

### 播放地址

接口 `/x/player/wbi/playurl`：

- `fnval=1` → 返回整段 mp4（`durl`），可直接交给 AVPlayer
- `fnval=4048` → 返回 DASH 分片（音视频分离）

**CDN 会校验 UA**：不带浏览器 UA 或使用 `curl` 的 UA 一律返回 `403`。因此播放器必须显式注入 `User-Agent` 和 `Referer`（见 `video_page.dart` 的 `httpHeaders`）。

未登录状态下清晰度上限为 720P（`qn=64`）。

### 弹幕

`https://comment.bilibili.com/{cid}.xml` 返回的是 **raw deflate** 压缩的 XML —— 既不是 gzip 也不是带 zlib 头的常规 deflate，必须用 `ZLibDecoder(raw: true)` 解压。

渲染层（`danmaku_overlay.dart`）的设计：

- 加载时用 `TextPainter` 预排版，并贪心分配轨道，避免同轨重叠
- 位置由播放进度推导，因此暂停 / 拖动进度条时弹幕自动同步
- `video_player` 的位置回调约 200ms 一次，用 `Ticker` 做时间外推，保证 60fps 平滑

## 构建

### 通过 GitHub Actions（推荐，无需 Mac）

推送到 `main` 分支或手动触发 `workflow_dispatch`，工作流会自动：

1. 在 `macos-latest` 上安装 Flutter
2. `flutter analyze` + `flutter test`
3. `flutter build ios --release --no-codesign`
4. 打包成 **未签名 ipa**，作为 artifact 上传

产物在 Actions 运行页面的 **Artifacts → BiliPure-unsigned-ipa** 下载。

### 安装到 iPhone

未签名 ipa 需要自行签名后安装，常见方式：

- **AltStore / SideStore**：导入 ipa，用你的 Apple ID 重签
- **TrollStore**：支持的设备可直接安装
- **Xcode**：`flutter build ios` 后连接真机运行

> 免费 Apple ID 签名的应用有效期为 7 天，过期需重签。

### 本地构建（需要 Mac）

```bash
flutter pub get
cd ios && pod install && cd ..
flutter build ios --release --no-codesign
```

## 免责声明

本项目为个人学习项目，与哔哩哔哩官方无关。所有内容版权归原作者所有。
