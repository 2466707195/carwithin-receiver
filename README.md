# CarWithin 接收端

CarWithin 的**原生 iOS 接收端**。CarWithin 在 iPhone 上把本机 CarPlay 画面通过 WebSocket 推出来，
这个 App 用来在另一台 iPhone / iPad 上接收这块画面，并把触摸回传给 CarPlay。

比用浏览器接收的好处：

- 原生 VideoToolbox 硬解 H.264 / H.265，不依赖车机浏览器的 MSE 能力；
- 触摸直接走 UIKit 多点触控，捏合、旋转、拖动都原样回传；
- 没有浏览器地址栏、没有「开始播放」按钮，连上就是全屏。

## 使用

1. iPhone 打开 CarWithin → 保存 Wi-Fi 信息 → 启动 CarPlay。
2. 「设置 → 当前输出」选 **浏览器** → 「输出设置」打开 **局域网接收页**。
3. 两台设备连同一 Wi-Fi。接收端 App 里点「扫描局域网」会自动发现，或手动填 CarWithin 显示的
   HTTP 地址（默认端口 `9888`）。
4. 点「连接」。出画面后直接在画面上点按、滑动，触控会回传。
5. 右上角图表按钮可看编码、分辨率、帧率、延迟、码率、丢帧。

伴音需要在 CarWithin 的「声音」里选 **随画面传输（Wi-Fi）**，否则只有画面。

## 协议（来自 CarWithin 1.0.5 源码）

连接 `ws://<iPhone IP>:9888/stream`，走 HTTP 端口，不需要证书。

客户端 → 服务端（JSON 文本帧）：

```json
{"type":"ready","decoder":"webcodecs","viewer":"<uuid>","audioClock":true}
{"type":"display","w":1179,"h":2556,"dpr":3,"sw":1179,"sh":2556,"hz":60,"h265":false,"fullscreen":true,"ua":"..."}
{"type":"ping","t0":<单调时钟 µs>}
{"type":"keyframe","reason":"..."}
{"type":"touches","points":[{"id":0,"x":0.5,"y":0.5}]}
{"type":"audio","enabled":true}
```

服务端 → 客户端：

- `{"type":"hello", ...}`、`{"type":"status","text":...}`、`{"type":"pong","s":...,"t0":...}`
- `{"type":"format","codec":"avc1.640028","name":"H.264","width":1280,"height":720,"fps":30,"decoder":"webcodecs","description":"<base64 avcC/hvcC>"}`
- 二进制帧：`1 字节类型（0 依赖帧 / 1 关键帧 / 3 音频）+ 8 字节大端到达时间(µs) + 数据`
  - 视频数据是 4 字节长度前缀的 NAL（AVCC/HVCC）
  - 音频数据：`[9..12] 采样率 BE`、`[13] 声道`、`[14] 流号`、`[15...] Int16 小端交错样本`

声明 `decoder: "webcodecs"` 才会收到「关键帧/依赖帧 + 时间戳」这种低延迟包；声明 `mse` 会收到
fMP4 分段，那是给浏览器 MSE 用的。

## 构建

Windows / Linux 上没有 Mac 也能出包：推代码到 GitHub，Actions 用 macOS runner 编出
**未签名 ipa**（`ios-unsigned-ipa`），下载后用全能签 / ESign 重签安装。

```bash
gh workflow run ios-build.yml
gh run download <run-id> -n ios-unsigned-ipa -D build
```

## 说明

- 只用 CarWithin 的公开输出协议，不含 CarWithin 的任何代码；CarWithin 本身是 GPL-3.0-or-later。
- 局域网内没有鉴权，和浏览器接收页一样，能连上地址的设备都能看和点。
