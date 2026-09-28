# 官网飞碟 3D 模型

飞碟由 Three.js 网格建模，再用固定相机渲染为透明 PNG。飞碟与地面均使用内嵌 PNG，页面不需要 WebGL 或下载运行库。原始品牌 Logo 未修改。

## 产物

- [可编辑 GLB 模型](../../assets/website-ufo-3d/ufo.glb)
- [官网角度渲染](../../assets/website-ufo-3d/ufo-hero.png)：3072×2048，透明背景，以 2× 像素密度对应原主图的 1536×1024 布局坐标。
- [底视检查图](../../assets/website-ufo-3d/ufo-underside.png)：展示整圈舷窗。
- [几何检查数据](../../assets/website-ufo-3d/geometry.json)：每扇窗的角度、半径、法线及开孔检查结果。

## 重建

需要 Node.js 和已安装的 Google Chrome。在仓库根目录运行：

```sh
npm ci --prefix scripts/website-ufo-3d
npm run render --prefix scripts/website-ufo-3d
```

同时更新 HTML 中的飞碟图层：

```sh
npm run render --prefix scripts/website-ufo-3d -- --embed
```

渲染器只临时监听本机回环地址，完成后自动关闭。静态资源均来自本地依赖。

## 几何和相机

建模、材质和灯光集中在 `scene.js`。碟身半径为 3.7；12 个圆窗以 30° 等间隔落在半径 2.96 的圆周上。底板真实开孔，每扇窗含窗壁、薄金属口沿、内嵌玻璃和暗色内衬；窗件朝向采用所在曲面的法线。不存在屏幕坐标补位或单独缩放左右圆窗。

主图采用仰视 14.5°、画面内顺时针倾斜 18° 的正交相机，以贴合原海报透视和构图。底视检查采用仰视 65°。圆顶高光来自环境和灯光反射。

画面以 3× 分辨率配合抗锯齿渲染，再缩采样为 2× PNG，保留细碟缘和窗框。旋转体使用平滑截面曲线；圆顶、倒角与窗框增加几何细分。宽面光源、较柔和的金属反射和带渐变的发光面用于减少生硬亮斑与纯白贴片感。

每次渲染自动检查等角度间距、轨道半径、单位法线、射线穿过真实开孔，以及 GLB 重新加载后的圆窗数量。官网光柱由 Canvas 绘制，从主图中发光口的投影位置延伸到地面，近侧光束与局部散射叠加在飞碟前方。光柱、旋转烟尘与飞碟共享发光口锚点和上下浮动偏移。若调整模型位置或相机，需同步更新 HTML 中的 `aperture` 投影参数。

地面使用静态陨石坑背景 [crater-ground-static.png](../../assets/website-ufo-3d/crater-ground-static.png)，保留坑沿、凹陷和细砂的摄影质感。已移除三维地面渲染和逐行贴图投影；地面不再移动、变形或改变亮度。UFO 浮动、光柱、扬尘与星空动画继续独立运行。源图通过内置 imagegen 生成，[提示词记录](../../assets/website-ufo-3d/crater-ground-static.md)。

以下为早期平面地表实验的源图和生成记录，当前页面不再使用此贴图。

地表源图：[crater-terrain.png](../../assets/website-ufo-3d/crater-terrain.png)，通过内置 imagegen 生成，保留用于设计参考。生成提示词：

```text
Use case: photorealistic-natural. Asset type: seamless square terrain texture for a moving 3D ground plane in a cinematic monochrome UFO website. Generate a photorealistic straight-down orthographic orbital photograph of a dry Mars-like heavily weathered impact-crater plain. STRICT grayscale black white neutral gray, no red. Entire square covered with continuous dusty regolith and subtle geological relief. Roughly 12-18 irregular impact craters of varied sizes, largest crater about 15 percent of image width, many tiny eroded impact pits; naturally uneven broken raised rims, bowl depressions with darker interiors, gentle ejecta aprons blending into wind-eroded fine dusty sand and subtle rock striations. Low grazing light from upper left gives physically credible slopes and soft shadows. A few craters partially overlap. Fine photographic granularity and believable scale, not graphic outlines, not neat repeated circles, not rocky boulders. Moderately contrasty midgray surface, visible detailed texture, not pure black backdrop. Texture is truly seamless tileable on all four edges; avoid distinctive giant central crater. No perspective, no horizon, no sky, no planet curvature, no stars, no spacecraft, no objects, no words, no watermark. Square 2048x2048 if possible.
```

技术参考：[Three.js 文档](https://threejs.org/docs/)。
