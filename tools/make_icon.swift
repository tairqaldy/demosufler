// Рисует иконку приложения: swift tools/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Чёрная плитка по сетке иконок macOS.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.addPath(shape)
ctx.clip()
let colors = [CGColor(gray: 0.13, alpha: 1), CGColor(gray: 0.0, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.resetClip()
ctx.addPath(shape)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
ctx.setLineWidth(6)
ctx.strokePath()

// Камера сверху по центру.
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 512 - 26, y: 792, width: 52, height: 52))
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 512 - 10, y: 808, width: 20, height: 20))

// Строки текста под камерой, уходящие в темноту.
let lines: [(width: CGFloat, alpha: CGFloat)] = [(560, 1.0), (470, 0.72), (530, 0.42), (360, 0.18)]
var y: CGFloat = 640
for line in lines {
    let rect = CGRect(x: 232, y: y, width: line.width, height: 62)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 31, cornerHeight: 31, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: line.alpha))
    ctx.fillPath()
    y -= 124
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
