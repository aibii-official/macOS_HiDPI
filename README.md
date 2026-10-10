# macOS_HiDPI

一条命令为非 Retina 外接显示器（1080p / 2K）开启 macOS 原生 HiDPI 缩放。
不装 App、不装驱动、不关闭 SIP、无常驻进程，卸载即完全还原。

## 背景

macOS 只对 4K 及以上分辨率的显示器原生提供 HiDPI 缩放。2K（2560×1440）和 1080p
显示器只能选原生分辨率（字偏小）或不带 HiDPI 的低分辨率（画面发虚）。
本脚本通过 macOS 官方机制补上中间档的 HiDPI 缩放（如 2K 屏的 2048×1152 HiDPI）。

## 原理

macOS 会按「厂商 ID + 产品 ID」读取
`/Library/Displays/Contents/Resources/Overrides/` 下的显示器配置，把其中
`scale-resolutions` 列表里带 HiDPI 标志的分辨率当作显示器原生支持的模式。
脚本自动枚举当前连接的显示器、生成上述配置（二进制 plist，格式与
`/System` 下苹果自带配置一致），并打开 WindowServer 的
`DisplayResolutionEnabled` 开关。全程只写 `/Library`，不碰系统卷。

## 特性

- **通用**：自动识别当前连接的任意显示器；换新显示器后重跑一次 `install` 即可
- **智能跳过**：自动跳过内置屏和原生 ≥4K 的屏（本来就支持 HiDPI），`--force` 可强制
- **多档 HiDPI**：注入 1280×720 / 1440×810 / 1600×900 / 1920×1080 / 2048×1152 / 2240×1260
- **完全可逆**：`uninstall` 删除全部注入并还原系统开关
- **零依赖**：纯 shell + macOS 自带工具，两百余行源码可直接审计

## 使用方法

```bash
chmod +x hidpi2k.sh

./hidpi2k.sh install      # 注入 HiDPI 配置（会提示输入一次开机密码）
./hidpi2k.sh list         # 列出所有显示器及判定结果（可注入 / 跳过及原因）
./hidpi2k.sh status       # 总览：SIP、系统开关、已注入列表
./hidpi2k.sh uninstall    # 完全卸载还原（--all 跳过交互）

# 可选参数
./hidpi2k.sh install --all      # 多台外接屏时全部注入，免交互
./hidpi2k.sh install --force    # 强制处理被自动跳过的屏
```

**安装后**：注销或重启一次，然后到
「系统设置 → 显示器」按住 **Option** 点「缩放」（或开启"显示所有分辨率"），
选择带 HiDPI 效果的档位。

## 推荐档位

| 屏幕 | 推荐档位 | 说明 |
| --- | --- | --- |
| 27" 2K（2560×1440） | **2048×1152 HiDPI** | 字大小与清晰度最均衡 |
| 24" 1080p（1920×1080） | **1280×720 HiDPI** | 字大小适中，远好于原生小字 |
| 任意屏 | 1280×720 / 960×540 HiDPI | 完美 2× 整数缩放，最锐利但字偏大 |

> HiDPI 先按 2 倍渲染再缩放到物理像素。非整数倍档位（如 2K 用 2048×1152）
> 锐利度略低于完美 2× 档，但仍远好于非 HiDPI 低分辨率的粗暴放大。

## 注意事项

- 安装 / 卸载后需要**注销或重启**一次才生效
- 高刷新率（如 144Hz）下若个别高档位不出现，将显示器切到 60Hz 后重新注销登录即可
- 已在 macOS 27（Apple Silicon）实测；更早版本理论可用，欢迎反馈

## 常见问题

**Q：装完没看到 HiDPI 档位？**
先确认已注销/重启；运行 `./hidpi2k.sh status` 确认注入存在；再尝试把刷新率降到 60Hz。

**Q：安全吗？**
脚本只写入 `/Library/Displays/` 下一个配置文件和一个 `defaults` 开关，
`uninstall` 后系统完全恢复原状。

## 致谢

原理与 one-key-hidpi 相同（display override + WindowServer 开关），
本项目的差异：不绑定特定显示器、自动跳过无需注入的屏、优先写 `/Library`
（无需关 SIP），并兼容 macOS 自带 bash 3.2 的多字节解析缺陷。
