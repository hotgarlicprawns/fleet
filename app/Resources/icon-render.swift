import AppKit
import CoreGraphics

// Fleet app icon: a 2x2 grid of terminal panes on the app's own dark ground,
// one pane lit in the app's own accent teal — the exact "something needs
// you" signal already used inside the app (the waiting-dot / accent border),
// not an arbitrary logo. Colors are Theme.swift's real values, not new ones.

let size = 1024.0
let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                     bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let ground = rgb(0x0c, 0x0f, 0x14)
let panel  = rgb(0x1b, 0x21, 0x2c)
let line   = rgb(0x31, 0x3a, 0x47)
let accent = rgb(0x5f, 0xe3, 0xc2)
let accentDeep = rgb(0x08, 0x11, 0x0e)

// macOS masks the icon itself with rounded-square + padding, so this canvas
// fills edge to edge — the system supplies the outer squircle and shadow.
let corner: CGFloat = 220
let full = CGRect(x: 0, y: 0, width: size, height: size)

// Background: the app's own ground color, with a faint radial lift toward
// center so it doesn't read as a flat void at a glance.
ctx.addPath(CGPath(roundedRect: full, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.clip()
ctx.setFillColor(ground)
ctx.fill(full)
let colors = [rgb(0x14, 0x19, 0x22, 1), ground] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawRadialGradient(grad, startCenter: CGPoint(x: size / 2, y: size * 0.62), startRadius: 0,
                        endCenter: CGPoint(x: size / 2, y: size * 0.62), endRadius: size * 0.75,
                        options: [])

// 2x2 pane grid, inset with generous margin (icons read best with breathing
// room — the real app's own pane grid has almost none, this needs more).
let margin: CGFloat = 190
let gap: CGFloat = 40
let gridRect = full.insetBy(dx: margin, dy: margin)
let cell = (gridRect.width - gap) / 2
let paneCorner: CGFloat = 46

func paneRect(_ col: Int, _ row: Int) -> CGRect {
    CGRect(x: gridRect.minX + CGFloat(col) * (cell + gap),
           y: gridRect.minY + CGFloat(row) * (cell + gap),
           width: cell, height: cell)
}

// row 0 = bottom in CG's flipped-for-PDF coordinate space (origin bottom-left)
let panes: [(Int, Int, Bool)] = [ (0, 1, false), (1, 1, false), (0, 0, false), (1, 0, true) ]
for (col, row, lit) in panes {
    let r = paneRect(col, row)
    let path = CGPath(roundedRect: r, cornerWidth: paneCorner, cornerHeight: paneCorner, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(lit ? accent : panel)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(lit ? accent : line)
    ctx.setLineWidth(lit ? 0 : 6)
    ctx.strokePath()
}

// A soft glow behind the lit pane — same idea as the in-app "waiting" accent
// border, just given room to breathe at icon scale.
let litRect = paneRect(1, 0)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 90, color: accent.copy(alpha: 0.55))
let glowPath = CGPath(roundedRect: litRect, cornerWidth: paneCorner, cornerHeight: paneCorner, transform: nil)
ctx.addPath(glowPath)
ctx.setFillColor(accent)
ctx.fillPath()
ctx.restoreGState()
// redraw crisp on top (the shadow pass above blurs the fill edges too)
ctx.addPath(glowPath)
ctx.setFillColor(accent)
ctx.fillPath()

// A tiny "cursor" mark inside the lit pane — the one concrete detail that
// survives down to 32px, reading as "a terminal, ready for you."
let cursorW: CGFloat = cell * 0.16
let cursorH: CGFloat = cell * 0.34
let cursorRect = CGRect(x: litRect.minX + cell * 0.18, y: litRect.midY - cursorH / 2, width: cursorW, height: cursorH)
ctx.addPath(CGPath(roundedRect: cursorRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
ctx.setFillColor(accentDeep)
ctx.fillPath()

guard let cgImage = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")

// Regenerate: swift icon-render.swift icon-1024.png
// Then rebuild the .icns:
//   ICONSET=/tmp/Fleet.iconset; rm -rf $ICONSET; mkdir -p $ICONSET
//   for sz in 16 32 64 128 256 512; do sips -z $sz $sz icon-1024.png --out $ICONSET/icon_${sz}x${sz}.png >/dev/null; done
//   sips -z 32 32 icon-1024.png --out $ICONSET/icon_16x16@2x.png >/dev/null
//   sips -z 256 256 icon-1024.png --out $ICONSET/icon_128x128@2x.png >/dev/null
//   sips -z 512 512 icon-1024.png --out $ICONSET/icon_256x256@2x.png >/dev/null
//   cp icon-1024.png $ICONSET/icon_512x512@2x.png
//   iconutil -c icns $ICONSET -o AppIcon.icns
