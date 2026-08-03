#!/usr/bin/env swift

// Draws the README's download button.
//
//     swift scripts/make-button.swift assets/download-button.png
//
// GitHub strips CSS from a README, so a button cannot be styled into being — it has to arrive as an
// image wrapped in a link. Hence a drawn one rather than a badge service: nothing to fetch at page
// load, nothing to go down, and the shape can be the panel's own instead of somebody else's.
//
// It is the green of the dot, which is the only colour the app spends on saying "there is something
// here for you", and the corner radius the rows use. Dark text on that green rather than white:
// it is a light green, and white on it fails contrast at the size a button is read.
//
// Rendered at 3x and shown at a third of that, so it stays crisp on a Retina display. The script
// prints the width to give the img tag, since that is the one number the README has to agree with.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-button.swift <out.png>\n".utf8))
    exit(2)
}
let destination = URL(fileURLWithPath: arguments[1])

let scale: CGFloat = 3
let label = "Download for macOS"
let font = NSFont.systemFont(ofSize: 17 * scale, weight: .semibold)

/// Attention.doneColor, the dot's own green, and a near-black with a little green left in it so the
/// text does not read as a foreign colour dropped onto the fill.
let fill = NSColor(srgbRed: 0.22, green: 0.80, blue: 0.46, alpha: 1)
let ink = NSColor(srgbRed: 0.04, green: 0.13, blue: 0.08, alpha: 1)

let padding = 24 * scale
let arrowWidth = 15 * scale
let gap = 11 * scale
let height = 52 * scale
let textWidth = NSAttributedString(string: label, attributes: [.font: font]).size().width
let width = (padding + arrowWidth + gap + textWidth + padding).rounded()

guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("make-button: could not create a context\n".utf8))
    exit(1)
}

// Radius 18 on a 52 tall button: the proportion the panel's own rows carry.
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                   cornerWidth: 18 * scale, cornerHeight: 18 * scale, transform: nil))
ctx.setFillColor(fill.cgColor)
ctx.fillPath()

// A downward arrow, drawn rather than set in a font: a glyph would depend on the font being there
// wherever this is next run, and this is three lines.
let arrow = CGRect(x: padding, y: (height - 20 * scale) / 2, width: arrowWidth, height: 20 * scale)
ctx.setStrokeColor(ink.cgColor)
ctx.setFillColor(ink.cgColor)
ctx.setLineWidth(2.6 * scale)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: arrow.midX, y: arrow.maxY))
ctx.addLine(to: CGPoint(x: arrow.midX, y: arrow.minY + arrow.height * 0.46))
ctx.strokePath()
let head = arrow.width * 0.78
ctx.move(to: CGPoint(x: arrow.midX - head / 2, y: arrow.minY + arrow.height * 0.50))
ctx.addLine(to: CGPoint(x: arrow.midX + head / 2, y: arrow.minY + arrow.height * 0.50))
ctx.addLine(to: CGPoint(x: arrow.midX, y: arrow.minY + arrow.height * 0.14))
ctx.closePath()
ctx.fillPath()

let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
    .font: font, .foregroundColor: ink,
]))
var ascent: CGFloat = 0, descent: CGFloat = 0
CTLineGetTypographicBounds(line, &ascent, &descent, nil)
// Centred on the cap height rather than the line box, which sits text visibly low in a button.
ctx.textPosition = CGPoint(x: padding + arrowWidth + gap, y: (height - (ascent - descent)) / 2)
CTLineDraw(line, ctx)

guard let image = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("make-button: could not encode the button\n".utf8))
    exit(1)
}
try data.write(to: destination)
print("wrote \(destination.path) at \(Int(width))x\(Int(height)); show it at width=\(Int(width / scale))")
