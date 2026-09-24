# 引导演示背景素材

- 用途：欢迎页聊天演示、第 2 步模型对比、第 4 步快捷键、第 5 步试用的静态背景。语音识别和权限页保留原有卡片。
- 来源：2026-09-22 使用内置 imagegen 工具生成，未使用 CLI。欢迎页原图无外部参考，其余三张以该原图为风格参考，分别生成不同构图。
- 规格：PNG，统一显示在 640 × 366pt、20pt 圆角的演示区内，等比填充裁切；外层主视觉区高 390pt。
- 视觉：沿用原生界面的蓝灰色和低对比纸张纹理，细节集中在边缘，不增加人物、Logo 或图中文字。聊天窗口、模型对比卡片和试用输入卡片使用独立的实色背景，提示不直接叠在图片上。
- 深浅色：每页使用自己的图片，深色模式由 SwiftUI 叠加 72% 黑色遮罩，不改变原始图片或前景控件。

所有文件均保存在 `app/MemoEcho/Resources/Assets.xcassets/` 下，通过 asset 名称访问，不依赖生成工具的输出目录。

| 页面 | 保存路径（相对上述目录） | 原始尺寸 | 构图 |
| --- | --- | --- | --- |
| 欢迎页 | `OnboardingDemoBackground.imageset/background.png` | 1774 × 887 | 层叠纸张与远景曲线 |
| 第 2 步模型 | `OnboardingModelBackground.imageset/background.png` | 1672 × 941 | 对角折面与纸张叠层 |
| 第 4 步快捷键 | `OnboardingHotkeyBackground.imageset/background.png` | 1672 × 941 | 宽幅弧线与柔和阴影 |
| 第 5 步试用 | `OnboardingTrialBackground.imageset/background.png` | 1672 × 941 | 偏暖象牙白与纸带曲线 |

## 生成提示词

### 欢迎页原图

```text
Use case: stylized-concept. Asset type: a single production background image for a native macOS application's onboarding demonstration panel, not a UI mockup. Primary request: a quiet, elegant desktop-wallpaper-like background behind existing chat UI and keyboard keycaps. Wide landscape approximately 2:1 aspect ratio, at least 1280 pixels wide. Scene/backdrop: softly lit broad overlapping matte paper contours, gently curved like a distant rolling landscape, nearly abstract, with subtle physical surface texture. Color palette: restrained cool light gray, misty blue, and a small amount of muted deeper blue, matching a native blue-accent macOS interface. Composition: large, calm, bright central area occupying most of the image for the UI to overlay; contour detail concentrated toward the outer edges and lower corners. Soft daylight, low contrast, crisp premium image quality without blur or noise. This is only the background, so do not draw any windows, keyboards, chat bubbles, UI elements, borders, text, letters, people, logos, icons or watermarks. No neon colors, no purple, no glowing blobs, no extra decorative objects. Full bleed, no frame.
```

### 第 2 步模型

```text
Use case: stylized-concept. Input image 1 is a STYLE REFERENCE ONLY, not an edit target. Generate one new production wallpaper for a native macOS onboarding demo. Match the reference's matte layered-paper texture, soft natural light, restrained blue-gray palette and low contrast, but create a clearly different composition, not a recolor or crop. Landscape 16:9, at least 1280 pixels wide. Keep the central 75% calm and bright for opaque UI panels to overlay. Full-bleed background image only, no UI, no text, no symbols, no logos, no frames, no objects, no neon or purple. Variation: broad overlapping paper sheets fan gently inward from the upper-left and lower-right edges, with subtle straight folds and diagonal layered planes. Pale silver, misty slate blue and off-white. The effect should feel orderly and quiet, distinct from rolling hills.
```


### 第 4 步快捷键

```text
Use case: stylized-concept. Input image 1 is a STYLE REFERENCE ONLY, not an edit target. Generate one new production wallpaper for a native macOS onboarding demo. Match the reference's matte layered-paper texture, soft natural light, restrained blue-gray palette and low contrast, but create a clearly different composition, not a recolor or crop. Landscape 16:9, at least 1280 pixels wide. Keep the central 75% calm and bright for opaque UI panels to overlay. Full-bleed background image only, no UI, no text, no symbols, no logos, no frames, no objects, no neon or purple. Variation: a few generous curved paper arches sweep from the upper-right corner toward the lower-left edge. Rounded sculptural contours with soft natural shadows, misty steel blue and pearl gray, preserving a wide open center. Not horizontal hills and not straight folded sheets.
```


### 第 5 步试用

```text
Use case: stylized-concept. Input image 1 is a STYLE REFERENCE ONLY, not an edit target. Generate one new production wallpaper for a native macOS onboarding demo. Match the reference's matte layered-paper texture, soft natural light, restrained blue-gray palette and low contrast, but create a clearly different composition, not a recolor or crop. Landscape 16:9, at least 1280 pixels wide. Keep the central 75% calm and bright for opaque UI panels to overlay. Full-bleed background image only, no UI, no text, no symbols, no logos, no frames, no objects, no neon or purple. Variation: a soft paper ribbon curves along the lower-left edge and recedes into the upper-right, leaving a large serene center. Mostly warm ivory and soft neutral gray, with restrained misty blue on the outer layers, cohesive with the reference but slightly warmer. Fine matte paper texture, no sharp central detail.
```
