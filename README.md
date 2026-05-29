# Orbbec Test

macOS 上的奥比中光 / OpenNI 旧款 3D 相机测试项目。当前实现包含：

- 设备信息读取：SDK 版本、设备名、序列号、固件版本、VID/PID、连接类型
- 相机参数读取：Depth/RGB 内参、畸变、Depth 到 RGB 外参
- macOS 原生 viewer：RGB、Depth、Point Cloud 三路独立开关
- 单帧保存：RGB PNG、Depth 可视化 PNG、Depth 16-bit PGM、Point Cloud PLY

## 当前相机适配说明

这台相机在 OrbbecSDK v1 中识别为：

```text
Name: SL1000S_U3
VID/PID: 0x2bc5/0x060b
Connection: USB2.0
```

这个设备的 RGB 在 macOS 上会作为 UVC 摄像头暴露，所以项目采用：

- Depth / 参数 / 点云：OrbbecSDK C/C++ v1.10.16
- RGB 视频：macOS AVFoundation

`pyorbbecsdk2` 已验证不能稳定识别这个旧 OpenNI 设备，因此不是本项目依赖。

## 依赖

必需：

- macOS
- Xcode Command Line Tools
- OrbbecSDK C/C++ v1.10.16 for macOS arm64/x86
- Python 3，仅用于把文本参数报告整理成 JSON 摘要

不需要：

- Homebrew
- CMake
- OpenCV
- pyorbbecsdk / pyorbbecsdk2
- Qt

安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

## 安装 OrbbecSDK

从奥比中光官方渠道下载 macOS arm64/x86 的 C/C++ SDK v1.10.16，并解压到下面这个结构：

```text
OrbbecTest/
  sdk_v1_10_16/
    OrbbecSDK_C_C++_v1.10.16_20241021_c0329e3_macos_arm64_x86/
      SDK/
        include/
        lib/
```

本仓库不提交 SDK 压缩包、dylib、构建产物和本地输出文件；这些都由本地安装或构建生成。

## 读取参数

快速读取设备 metadata、profile、标定参数，并生成文本和 JSON：

```bash
cd OrbbecTest
scripts/read_intrinsics_metadata.sh
```

输出位置：

```text
outputs/orbbec_intrinsics_v1.txt
outputs/orbbec_intrinsics_summary.json
```

如果要手动分步运行：

```bash
scripts/build_intrinsics_probe.sh
bin/read_orbbec_intrinsics_v1 --metadata-only
python3 scripts/make_intrinsics_summary_json.py
```

`--metadata-only` 会跳过启流，避免旧 OpenNI 设备在停止深度流时偶发等待较久。

## 构建 viewer

```bash
cd OrbbecTest
viewer/build_viewer.sh
```

生成：

```text
build/OrbbecViewer.app
```

启动：

```bash
open build/OrbbecViewer.app
```

首次打开 RGB 时，macOS 会请求摄像头权限。允许后 viewer 会优先选择名称里包含 `USB` / `Orbbec` / `Camera` 的 UVC 摄像头。

## 保存文件

viewer 中点击保存按钮后，文件会写入：

```text
outputs/viewer_captures/
```

保存格式：

- RGB：`rgb_*.png`
- Depth：`depth_*_visual.png` 和 `depth_*_raw16.pgm`
- Point Cloud：`pointcloud_*.ply`

## 目录说明

```text
src/
  OrbbecViewer.mm                 macOS AppKit + AVFoundation + OrbbecSDK viewer
  read_orbbec_intrinsics_v1.cpp   OrbbecSDK v1 参数读取工具

scripts/
  build_intrinsics_probe.sh       编译参数读取工具
  read_intrinsics_metadata.sh     读取参数并生成 JSON 摘要
  make_intrinsics_summary_json.py 文本报告转 compact JSON

viewer/
  build_viewer.sh                 构建 .app
  Info.plist                      macOS app 配置和摄像头权限说明
```

## downloads 清理结论

之前 `downloads/` 里的三个文件都不需要提交：

- `pyorbbecsdk2-2.1.1-...whl`：不需要。这个 Python SDK 没有识别当前旧 OpenNI 设备。
- `cpython-3.13.13-...tar.gz`：不需要。最终方案不依赖单独打包的 Python runtime。
- `OrbbecSDK_C_C++_v1.10.16_...zip`：压缩包本身不需要。项目只需要你本机解压后的 OrbbecSDK 目录，且该第三方 SDK 不纳入 git。
