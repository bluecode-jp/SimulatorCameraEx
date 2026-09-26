#!/usr/bin/env swift
//
//  make-icon.swift — draw the SimulatorCameraEx app icon and write the
//  macOS AppIcon.appiconset (16…1024 px, 1x/2x) into the asset catalog.
//
//  Usage: swift scripts/make-icon.swift [output .appiconset directory]
//
//  Design: blue rounded square (macOS icon grid: 824 pt body on a 1024
//  canvas), white video camera, QR finder patterns in the camera body —
//  "a camera that shows codes".
//

import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "SimulatorCamera/Assets.xcassets/AppIcon.appiconset"

func drawIcon(size px: Int) -> CGImage {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)

    // Body: rounded square with a soft drop shadow, blue vertical gradient.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: CGColor(gray: 0, alpha: 0.30))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.40, blue: 0.96, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 0.33, green: 0.58, blue: 1.00, alpha: 1),
                                       CGColor(srgbRed: 0.09, green: 0.27, blue: 0.82, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    let white = CGColor(gray: 1, alpha: 1)
    let blue = CGColor(srgbRed: 0.12, green: 0.33, blue: 0.88, alpha: 1)

    // Camera: rounded body + lens wedge on the right.
    let cam = CGRect(x: 210, y: 330, width: 450, height: 364)
    ctx.addPath(CGPath(roundedRect: cam, cornerWidth: 72, cornerHeight: 72, transform: nil))
    ctx.setFillColor(white)
    ctx.fillPath()
    let wedge = CGMutablePath()
    wedge.move(to: CGPoint(x: 690, y: 470))
    wedge.addLine(to: CGPoint(x: 820, y: 390))
    wedge.addQuadCurve(to: CGPoint(x: 836, y: 410), control: CGPoint(x: 836, y: 390))
    wedge.addLine(to: CGPoint(x: 836, y: 614))
    wedge.addQuadCurve(to: CGPoint(x: 820, y: 634), control: CGPoint(x: 836, y: 634))
    wedge.addLine(to: CGPoint(x: 690, y: 554))
    wedge.closeSubpath()
    ctx.addPath(wedge)
    ctx.fillPath()

    // QR finder patterns (3 corners) + a few modules inside the camera body.
    let m: CGFloat = 26                      // module size
    let origin = CGPoint(x: 435 - m * 5.5, y: 512 - m * 5.5)  // 11x11 grid centred in the body
    func module(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1) {
        ctx.fill(CGRect(x: origin.x + CGFloat(x) * m, y: origin.y + CGFloat(y) * m,
                        width: CGFloat(w) * m, height: CGFloat(h) * m))
    }
    ctx.setFillColor(blue)
    for (fx, fy) in [(0, 0), (0, 7), (7, 7)] {  // CG y-up: bottom-left, top-left, top-right
        module(fx, fy, 4, 4)
        ctx.setFillColor(white); module(fx + 1, fy + 1, 2, 2); ctx.setFillColor(blue)
    }
    for (x, y) in [(5, 0), (6, 2), (8, 1), (10, 0), (9, 3), (5, 5), (7, 5), (10, 5), (5, 8), (5, 10), (8, 4)] {
        module(x, y)
    }
    return ctx.makeImage()!
}

// macOS icon set: (point size, scale) pairs.
let entries: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (pt, scale) in entries {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: drawIcon(size: px))
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
let catalog = (outDir as NSString).deletingLastPathComponent

// Same artwork as a plain image asset for the in-app header: the app icon
// from Icon Services can be a generic placeholder right after reinstalling.
let headerDir = "\(catalog)/HeaderIcon.imageset"
try FileManager.default.createDirectory(atPath: headerDir, withIntermediateDirectories: true)
for (px, name) in [(64, "header.png"), (128, "header@2x.png")] {
    let rep = NSBitmapImageRep(cgImage: drawIcon(size: px))
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(headerDir)/\(name)"))
}
let header: [String: Any] = [
    "images": [["idiom": "universal", "filename": "header.png", "scale": "1x"],
               ["idiom": "universal", "filename": "header@2x.png", "scale": "2x"]],
    "info": ["version": 1, "author": "xcode"],
]
try JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(headerDir)/Contents.json"))
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8)
    .write(to: URL(fileURLWithPath: "\(catalog)/Contents.json"))
print("wrote \(entries.count) icons to \(outDir)")
