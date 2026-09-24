# MemoEcho 品牌资源

采用用户确认的两种用途：白底黑灰倾斜飞碟作为 App Icon／Logo；带月牙、正立紧凑飞碟与底部小圆罩作为单色菜单栏模板。

## 文件

| 文件 | 用途 |
| --- | --- |
| `app-icon-master.png` | 1254×1254、不透明白底 App Icon 母图，图形与淡出光束均已包含 |
| `menu-bar-master.png` | 1254×1254、透明背景的黑色菜单栏母图，月牙和分隔缝透明 |
| `logo.png` | 1024×1024 导出 Logo，与 AppIcon 最大规格一致，用于 README |
| `preview.png` | 从实际导出资源渲染的明暗背景预览，含原始像素与 6 倍像素放大 |

母图通过内置 imagegen 工具从确认稿提取，保存在仓库中；重新导出不需要生成服务或用户机器上的外部文件。App Icon 保留原有 7.5% 外侧透明留白，并应用白色圆角底板与细边框；不再叠加旧 SVG 的内边距。菜单栏输出为 PNG 模板，不是矢量 PDF。

## 导出

在 macOS 仓库根目录运行：

```bash
swift scripts/generate_app_icon.swift assets/branding app/MemoEcho/Resources/Assets.xcassets
```

若系统的 `xcode-select` 仍指向 Command Line Tools，可以为当前命令指定 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/generate_app_icon.swift assets/branding app/MemoEcho/Resources/Assets.xcassets
```

脚本生成 AppIcon 的 10 档 PNG、菜单栏 24×18 px（1×）与 48×36 px（2×）PNG、两份 `Contents.json`，以及本目录的 Logo 和预览。模板实际图形宽 22 pt、高约 13 pt，等比例缩放，左右各留 1 pt。透明区域裁切只用于去除母图外侧留白，轮廓仍保留抗锯齿 alpha。以 `template-rendering-intent: template` 交给 macOS 着色，不能给月牙或间隙填不透明白色。

预览中的尺寸为导出文件的真实像素；显示器缩放或浏览器缩放可能改变屏幕上的显示尺寸。1× 的月牙与分隔缝会受像素覆盖率影响；2× 保留更多细节。资源验证不等于完成录音、识别、注入链路的运行验收。

## 母图生成提示词

生成方式：内置 `image_gen.imagegen`，非 CLI。分别使用确认后的 App Icon 展示稿和最终带月牙的菜单栏展示稿作为引用图片。

### App Icon

```text
Use case: background-extraction. Asset type: production macOS App Icon master, a single square PNG image, at least 1024x1024. Extract and faithfully reproduce ONLY the approved LARGE APP ICON artwork from the LEFT SIDE of the attached reference. Do not use the menu icons. Render the UFO and its gray beam on a perfectly opaque PURE WHITE SQUARE background. The square artwork should be full bleed, with NO rounded-square outline or border; production packaging will apply the rounded mask. No outside padding beyond the square, no presentation board, no text, no size samples. Keep the exact approved proportions within the square: the UFO's bounding width about 67 percent of canvas, canopy top about 20 percent down, body reaches from approximately 18 to 83 percent canvas width, underside aperture around 52 percent canvas height; pale gray beam projects down-left and fades diagonally out before the bottom. Original graceful clockwise tilted broad near-black saucer rim, very dark underside, dark-gray rounded canopy with one WHITE CRESCENT highlight on its left, small white elliptical light aperture, and natural pale-gray light fading softly into the white background. Body near #111111, underside #050505, canopy about #565656. No stars, no colors, no new details, no drop shadow, no texture, no tile/background gradient. Preserve the original silhouette and perspective, crescent, beam geometry, optical scale and positioning. Crisp clean professional production artwork, with flat grayscale craft and only the beam using a fade. This is asset extraction of the already approved design, NOT a redesign.
```

### Menu Bar

```text
Use case: background-extraction. Asset type: production macOS MENU BAR TEMPLATE GLYPH, single square PNG with genuine alpha transparency. Extract ONLY the latest upright black icon in the RIGHT-HAND Light panel of the attached approved board. Keep exactly that compact silhouette and proportions: a rounded top dome about 54 percent of saucer width, a curved crescent-shaped TRANSPARENT cutout on the dome's upper left, a clear TRANSPARENT narrow gap between dome and saucer, a horizontal broad but compact elliptical saucer, and a small solid downward half-ellipse light lens centered beneath it, separated by a narrow TRANSPARENT curved gap. ALL filled shapes PURE BLACK. All background, crescent hole, and separating gaps must be truly TRANSPARENT, not painted white. No white or gray fill anywhere. No outline card, no text, no app logo, no beam, no rings, no tilt, no gradients, no shadows, no background or fake transparency checkerboard. Render the single glyph large and sharp at 1024x1024 or greater, bounding box centered on the transparent square, occupying about 80 percent of canvas width and about 50 percent height. This is faithful production extraction of the approved MENU BAR ICON, not a redesign. Critical: do NOT stretch the saucer; keep the compact proportions from the right-hand Light example, including the crescent.
```
