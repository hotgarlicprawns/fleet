import SwiftUI

/// Shared visual language with the fleet landing page — same dark grounds,
/// same phosphor-teal accent, mono type for anything that reads as data or
/// a control, instead of stock AppKit blue/native chrome.
enum Theme {
    static let ground     = Color(red: 0x0c/255, green: 0x0f/255, blue: 0x14/255)
    static let panel      = Color(red: 0x14/255, green: 0x19/255, blue: 0x22/255)
    static let panel2     = Color(red: 0x1b/255, green: 0x21/255, blue: 0x2c/255)
    static let line       = Color(red: 0x23/255, green: 0x2a/255, blue: 0x35/255)
    static let lineStrong = Color(red: 0x31/255, green: 0x3a/255, blue: 0x47/255)
    static let ink        = Color(red: 0xdc/255, green: 0xe1/255, blue: 0xe8/255)
    static let inkSoft    = Color(red: 0x9a/255, green: 0xa4/255, blue: 0xb1/255)
    static let inkFaint   = Color(red: 0x6b/255, green: 0x74/255, blue: 0x80/255)
    static let accent     = Color(red: 0x5f/255, green: 0xe3/255, blue: 0xc2/255)
    static let accentInk  = Color(red: 0x9d/255, green: 0xef/255, blue: 0xd6/255)
    static let accentDeep = Color(red: 0x08/255, green: 0x11/255, blue: 0x0e/255) // text-on-accent
    static let amber      = Color(red: 0xe6/255, green: 0xb6/255, blue: 0x67/255)
    static let red        = Color(red: 0xf0/255, green: 0x91/255, blue: 0x7d/255)
    static let codex      = Color(red: 0.95, green: 0.58, blue: 0.29)

    static let mono = Font.system(.body, design: .monospaced)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A dark, hairline-bordered pill of mutually-exclusive options — the same
/// shape as the landing page's `.seg` control — standing in for SwiftUI's
/// native segmented Picker, which renders as stock blue/grey AppKit chrome.
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                let isOn = opt.0 == selection
                Button { selection = opt.0 } label: {
                    Text(opt.1)
                        .font(Theme.mono(11.5, .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isOn ? Theme.accentDeep : Theme.inkSoft)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(isOn ? Theme.accent : .clear)
                }
                .buttonStyle(.plain)
                if i < options.count - 1 { Rectangle().fill(Theme.line).frame(width: 1, height: 14) }
            }
        }
        .fixedSize()
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.lineStrong, lineWidth: 1))
    }
}

/// A dark dropdown chip — replaces the native Picker's grey well.
struct Chip<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var accentDot: Bool = false

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button(opt.1) { selection = opt.0 }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == selection }?.1 ?? "")
                    .font(Theme.mono(11.5, .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .menuStyle(.borderlessButton)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.lineStrong, lineWidth: 1))
        .fixedSize()
    }
}

/// Minimal +/- stepper matching the toolbar's mono/pill language — replaces
/// the native Stepper's tiny AppKit up/down arrows.
struct MiniStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...16

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus") { value = max(range.lowerBound, value - 1) }
            Text("\(value)").font(Theme.mono(12, .semibold)).foregroundStyle(Theme.ink)
                .frame(minWidth: 20).monospacedDigit()
            stepButton("plus") { value = min(range.upperBound, value + 1) }
        }
        .padding(.horizontal, 4)
        .background(Theme.panel2)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.lineStrong, lineWidth: 1))
    }

    private func stepButton(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 20, height: 22)
        }.buttonStyle(.plain)
    }
}

/// The pill-shaped action buttons from the landing page's `.btn` classes.
struct FleetButton: View {
    let title: String
    var systemImage: String? = nil
    var primary: Bool = false
    var tint: Color = Theme.accent
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(Theme.mono(11.5, .semibold)).lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(primary ? Theme.accentDeep : Theme.inkSoft)
            .background(primary ? tint : Theme.panel2)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(primary ? .clear : Theme.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
