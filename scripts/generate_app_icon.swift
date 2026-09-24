#!/usr/bin/env swift
// 从确认后的 PNG 母图导出 AppIcon、菜单栏模板和实际像素预览。
// swift scripts/generate_app_icon.swift assets/branding app/MemoEcho/Resources/Assets.xcassets
import AppKit
import Foundation

enum ExportError: Error {
    case usage, invalidImage(String), invalidMenuAlpha, emptyMenuImage, bitmapCreation, pngEncoding
}

func loadImage(_ url: URL) throws -> NSImage {
    guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
        throw ExportError.invalidImage(url.path)
    }
    return image
}

func bitmap(width: Int, height: Int, draw: (NSRect) throws -> Void) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw ExportError.bitmapCreation
    }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    NSColor.clear.setFill()
    rect.fill(using: .copy)
    try draw(rect)
    context.flushGraphics()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [.interlaced: false]) else {
        throw ExportError.pngEncoding
    }
    try data.write(to: url, options: .atomic)
}

func writeJSON(_ value: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

func drawPreview(_ rep: NSBitmapImageRep, in rect: NSRect) {
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

func appIcon(_ source: NSImage, pixels: Int) throws -> NSBitmapImageRep {
    try bitmap(width: pixels, height: pixels) { canvas in
        let side = CGFloat(pixels)
        // 母图包含完整构图，只添加 macOS 图标外侧透明留白。
        let plate = canvas.insetBy(dx: side * 0.075, dy: side * 0.075)
        let shape = NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.2237, yRadius: plate.height * 0.2237)
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        source.draw(in: plate, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        // 白色图标在浅色 Finder 背景上仍保留轮廓。
        NSColor(calibratedWhite: 0.80, alpha: 1).setStroke()
        shape.lineWidth = max(0.35, side * 0.0013)
        shape.stroke()
    }
}

/// 阈值只用于确定透明留白的边界，不二值化或改变轮廓。
func menuGlyph(_ url: URL) throws -> NSImage {
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)), rep.hasAlpha else {
        throw ExportError.invalidMenuAlpha
    }
    var left = rep.pixelsWide, top = rep.pixelsHigh, right = -1, bottom = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.06 else { continue }
            left = min(left, x); right = max(right, x)
            top = min(top, y); bottom = max(bottom, y)
        }
    }
    guard right >= left, bottom >= top, let original = rep.cgImage else { throw ExportError.emptyMenuImage }
    let bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    guard let cropped = original.cropping(to: bounds) else { throw ExportError.emptyMenuImage }
    return NSImage(cgImage: cropped, size: bounds.size)
}

func menuIcon(_ source: NSImage, scale: Int, ink: NSColor = .black) throws -> NSBitmapImageRep {
    // 24×18 pt 原生尺寸；图形宽 22 pt（高约 13 pt），左右各留 1 pt。
    try bitmap(width: 24 * scale, height: 18 * scale) { canvas in
        let width = CGFloat(22 * scale)
        let height = width * source.size.height / source.size.width
        let rect = NSRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        // 模板仅依赖 alpha；统一 RGB，避免母图亚像素色偏进入资源。
        ink.setFill()
        canvas.fill(using: .sourceIn)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("Usage: swift scripts/generate_app_icon.swift <branding_dir> <asset_catalog>")
    throw ExportError.usage
}
let sources = URL(fileURLWithPath: arguments[1], isDirectory: true)
let catalog = URL(fileURLWithPath: arguments[2], isDirectory: true)
let appSet = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let menuSet = catalog.appendingPathComponent("MenuBarIcon.imageset", isDirectory: true)
try FileManager.default.createDirectory(at: appSet, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: menuSet, withIntermediateDirectories: true)
let appMaster = try loadImage(sources.appendingPathComponent("app-icon-master.png"))
guard appMaster.size.width == appMaster.size.height, appMaster.size.width >= 1024 else {
    throw ExportError.invalidImage("App Icon master must be square and at least 1024 px")
}
let glyph = try menuGlyph(sources.appendingPathComponent("menu-bar-master.png"))
let info: [String: Any] = ["author": "xcode", "version": 1]
let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var appEntries: [[String: String]] = []
for (size, scale) in sizes {
    let filename = "app_icon_\(size)x\(size)@\(scale)x.png"
    try writePNG(appIcon(appMaster, pixels: size * scale), to: appSet.appendingPathComponent(filename))
    appEntries.append(["filename": filename, "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x"])
}
try writeJSON(["images": appEntries, "info": info], to: appSet.appendingPathComponent("Contents.json"))
var menuEntries: [[String: String]] = []
for scale in [1, 2] {
    let filename = "menuBarIcon@\(scale)x.png"
    try writePNG(menuIcon(glyph, scale: scale), to: menuSet.appendingPathComponent(filename))
    menuEntries.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x"])
}
try writeJSON([
    "images": menuEntries, "info": info,
    "properties": ["template-rendering-intent": "template"]
], to: menuSet.appendingPathComponent("Contents.json"))
try writePNG(appIcon(appMaster, pixels: 1024), to: sources.appendingPathComponent("logo.png"))

// 预览使用真实导出像素，不使用概念图中的尺寸示意。
let preview = try bitmap(width: 1000, height: 580) { canvas in
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill(); canvas.fill()
    func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 14, color: NSColor = .darkGray) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }
    label("MemoEcho — exported assets", x: 30, y: 532, size: 24, color: .black)
    for (pixels, x) in [(256, 25), (128, 300), (32, 455), (16, 520)] {
        let rep = try appIcon(appMaster, pixels: pixels)
        drawPreview(rep, in: NSRect(x: x, y: 230, width: pixels, height: pixels))
        label("\(pixels) px", x: CGFloat(x), y: 204)
    }
    for (index, dark) in [false, true].enumerated() {
        let x = CGFloat(595 + index * 195)
        let panel = NSRect(x: x, y: 65, width: 180, height: 430)
        (dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white).setFill(); panel.fill()
        let ink: NSColor = dark ? .white : .black
        label(dark ? "Dark template" : "Light template", x: x + 12, y: 467, color: ink)
        let one = try menuIcon(glyph, scale: 1, ink: ink)
        drawPreview(one, in: NSRect(x: x + 78, y: 410, width: 24, height: 18))
        label("24 × 18 px (1×)", x: x + 20, y: 380, color: ink)
        let two = try menuIcon(glyph, scale: 2, ink: ink)
        drawPreview(two, in: NSRect(x: x + 66, y: 315, width: 48, height: 36))
        label("48 × 36 px (2×)", x: x + 20, y: 285, color: ink)
        NSGraphicsContext.current?.imageInterpolation = .none
        drawPreview(one, in: NSRect(x: x + 18, y: 130, width: 144, height: 108))
        NSGraphicsContext.current?.imageInterpolation = .high
        label("1× pixels enlarged 6×", x: x + 12, y: 87, size: 12, color: ink)
    }
    label("App Icon: 16–1024 px · Menu Bar: template alpha, 1× / 2×", x: 30, y: 30)
}
try writePNG(preview, to: sources.appendingPathComponent("preview.png"))
print("Exported 10 App Icon PNGs, 2 menu template PNGs, Contents.json, logo.png and preview.png")
