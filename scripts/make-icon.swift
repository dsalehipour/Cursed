#!/usr/bin/env swift

// Turns a square piece of artwork into a macOS .icns, or into a single masked PNG.
//
//     swift scripts/make-icon.swift assets/icon.png Resources/cursed.icns
//     swift scripts/make-icon.swift assets/icon.png assets/icon-rounded.png 384
//
// Two things stand between generated artwork and an icon that looks native.
//
// The first is the shape. Artwork arrives as an opaque square, and an icon has to be a rounded
// mask on transparency or it sits in the Dock as a rectangle with painted-on corners. The mask is
// a squircle rather than a rounded rectangle: macOS uses a superellipse, whose curvature eases in
// continuously instead of meeting the straight edge at a hard join, and a circular-cornered
// rectangle next to real system icons reads as subtly wrong at exactly the sizes people see.
//
// The second is the grid. An icon body occupies 824pt of a 1024pt canvas, the margin being the
// room macOS expects for the shadow it draws. Artwork scaled to the full canvas looks oversized
// beside everything else in the Dock, which is the usual tell of an icon made by hand.
//
// The PNG output exists because anywhere the artwork is shown outside the app — a README, most of
// all — needs the same cut corners for the same reason: on any background that is not black, the
// unmasked source shows four dark triangles. It shares this path rather than getting a mask of its
// own so the two silhouettes cannot drift apart. What it drops is the shadow margin, there being
// no Dock shadow to leave room for: a transparent border would only make the image render smaller
// than the width it is given.

import AppKit

let arguments = CommandLine.arguments
guard (3...4).contains(arguments.count) else {
    FileHandle.standardError.write(Data("""
        usage: make-icon.swift <source.png> <out.icns>
               make-icon.swift <source.png> <out.png> [size]

        """.utf8))
    exit(2)
}
let sourcePath = arguments[1]
let destination = URL(fileURLWithPath: arguments[2])

/// Apple's icon grid: the body is 824 of 1024, so a little over 80%.
let iconBodyFraction = 824.0 / 1024.0
/// The exponent of the superellipse. Five is the value that matches the system shape.
let squircleExponent = 5.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

guard let image = NSImage(contentsOfFile: sourcePath),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail("could not read \(sourcePath)")
}

/// Cuts away the flat background that generated artwork tends to arrive on.
///
/// Such artwork usually wears a rounded shape of its own, floating on a background that fills the
/// corners. Clipping that to a squircle rounds something already round, and the background caught
/// between the two curves survives as four dark slivers at the corners — the tell of an icon
/// masked without looking at it.
///
/// The background is found by flooding inwards from the corners rather than by matching a colour
/// everywhere, because on this kind of artwork the corners are frequently no darker than the
/// subject: keying by colour alone would punch holes through the middle of the design. The flood
/// stops at the artwork's edge and cannot reach anything enclosed by it, so the test becomes
/// "connected to the outside" instead of "looks like the outside".
func keyOutBackground(of image: CGImage) -> CGImage {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return image
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Loose enough for the gradient and compression noise a flat background still has, tight
    // enough that a rim of any brightness stops the flood before it gets inside.
    let tolerance = 30
    let seed = (r: Int(pixels[0]), g: Int(pixels[1]), b: Int(pixels[2]))
    func matchesBackground(_ index: Int) -> Bool {
        abs(Int(pixels[index]) - seed.r) <= tolerance
            && abs(Int(pixels[index + 1]) - seed.g) <= tolerance
            && abs(Int(pixels[index + 2]) - seed.b) <= tolerance
    }

    var outside = [Bool](repeating: false, count: width * height)
    var queue = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
        .filter { matchesBackground(($0.1 * width + $0.0) * 4) }
    for start in queue { outside[start.1 * width + start.0] = true }

    var head = 0
    while head < queue.count {
        let (x, y) = queue[head]
        head += 1
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
            let cell = ny * width + nx
            guard !outside[cell], matchesBackground(cell * 4) else { continue }
            outside[cell] = true
            queue.append((nx, ny))
        }
    }

    // Coverage is averaged over each pixel's neighbours so the cut edge is anti-aliased rather
    // than a staircase; a hard binary mask reads as ragged at the sizes an icon is actually seen.
    var coverage = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            var total = 0, counted = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    total += outside[ny * width + nx] ? 0 : 255
                    counted += 1
                }
            }
            coverage[y * width + x] = UInt8(total / counted)
        }
    }

    for cell in 0..<(width * height) {
        let alpha = Int(coverage[cell])
        let i = cell * 4
        // Premultiplied, so the colour has to come down with the alpha or the edge fringes.
        pixels[i] = UInt8(Int(pixels[i]) * alpha / 255)
        pixels[i + 1] = UInt8(Int(pixels[i + 1]) * alpha / 255)
        pixels[i + 2] = UInt8(Int(pixels[i + 2]) * alpha / 255)
        pixels[i + 3] = coverage[cell]
    }

    return context.makeImage() ?? image
}

/// The smallest square, centred on the artwork, that holds everything left after the background
/// was cut away. Squared off around its own centre so nothing is stretched and the mask stays
/// concentric with whatever curve the artwork already has.
func artworkBounds(of image: CGImage) -> CGRect {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    let box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    let side = max(box.width, box.height)
    return CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
}

/// A superellipse: |x/a|ⁿ + |y/b|ⁿ = 1, walked as points rather than fitted with Béziers. At icon
/// resolutions a few hundred segments are already smoother than the pixel grid can show.
func squircle(in rect: CGRect, exponent: Double, segments: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...segments {
        let t = Double(step) / Double(segments) * 2 * .pi
        let cosine = cos(t), sine = sin(t)
        let x = pow(abs(cosine), 2 / exponent) * (cosine < 0 ? -1 : 1) * a
        let y = pow(abs(sine), 2 / exponent) * (sine < 0 ? -1 : 1) * b
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

let keyed = keyOutBackground(of: source)
let bounds = artworkBounds(of: keyed)
guard let artwork = keyed.cropping(to: bounds) else { fail("could not crop the artwork") }

func render(at size: Int, bodyFraction: Double) -> Data {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not create a \(size)px context")
    }
    context.interpolationQuality = .high

    let body = (Double(size) * bodyFraction).rounded()
    let inset = ((Double(size) - body) / 2).rounded()
    let frame = CGRect(x: inset, y: inset, width: body, height: body)

    context.addPath(squircle(in: frame, exponent: squircleExponent))
    context.clip()
    context.draw(artwork, in: frame)

    guard let rendered = context.makeImage() else { fail("could not render \(size)px") }
    let representation = NSBitmapImageRep(cgImage: rendered)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        fail("could not encode \(size)px")
    }
    return data
}

try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

func writeICNS() throws {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cursed-\(UUID().uuidString).iconset")
    try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            do {
                try render(at: base * scale, bodyFraction: iconBodyFraction)
                    .write(to: iconset.appendingPathComponent(name))
            } catch {
                fail("could not write \(name): \(error.localizedDescription)")
            }
        }
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
}

func writePNG(at size: Int) throws {
    try render(at: size, bodyFraction: 1).write(to: destination)
}

switch destination.pathExtension.lowercased() {
case "icns":
    if arguments.count == 4 { fail("a size applies to a PNG only; an .icns holds all of them") }
    try writeICNS()
case "png":
    guard let size = Int(arguments.count == 4 ? arguments[3] : "512"), size > 0 else {
        fail("size must be a positive whole number of pixels")
    }
    try writePNG(at: size)
default:
    fail("do not know how to write \(destination.lastPathComponent); expected .icns or .png")
}

let trimmed = Int(bounds.width)
print("trimmed artwork to \(trimmed)x\(trimmed) of \(source.width), wrote \(destination.path)")
