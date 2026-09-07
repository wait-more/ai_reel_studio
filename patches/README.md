# Pub 依赖补丁

本目录由 [`ft_patch_package`](https://pub.dev/packages/ft_patch_package) 管理。

| 文件 | 说明 |
|---|---|
| `xterm+4.0.0.patch` | Windows 中文 IME：正确上报 transform/`setComposingRect`；每次 paint/focus 刷新光标矩形（否则连接建立后仍停在 (0,0)） |

## 用法

```powershell
flutter pub get
powershell -ExecutionPolicy Bypass -File scripts/apply_patches.ps1
```

`scripts/pack_windows.ps1` 已自动执行 apply。
