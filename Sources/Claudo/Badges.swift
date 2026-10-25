import ClaudoCore
import SwiftUI

// MARK: - Status glyph (Linear-style, drawn so it stays crisp at any size)

/// A circle for work, a diamond for a decision (a call to make, not hours to spend). The shape says which;
/// color is kept for the status (doing blue, waiting amber, done green), so an open row is grey either way.
struct StatusGlyph: View {
    let status: TaskStatus
    var kind: TaskKind = .task
    var size: CGFloat = 15

    var body: some View {
        let line = max(1.4, size / 10)
        ZStack {
            switch status {
            case .todo:
                outline(Color.secondary.opacity(0.55), line)
            case .doing:
                outline(Palette.doing, line)
                if kind == .decision {
                    HalfDiamond().fill(Palette.doing).padding(size * 0.27)
                } else {
                    HalfDisc().fill(Palette.doing).padding(size * 0.23)
                }
            case .waiting:
                outline(Palette.waiting, line)
                PauseBars().fill(Palette.waiting).frame(width: size * 0.34, height: size * 0.34)
            case .done:
                solid(Palette.done)
                CheckShape().stroke(.white, style: StrokeStyle(lineWidth: line * 1.15, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.46, height: size * 0.36)
            case .dropped:
                solid(Palette.quiet.opacity(0.7))
                CrossShape().stroke(.white, style: StrokeStyle(lineWidth: line * 1.1, lineCap: .round))
                    .frame(width: size * 0.32, height: size * 0.32)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func outline(_ color: Color, _ line: CGFloat) -> some View {
        if kind == .decision {
            DiamondShape().stroke(color, style: StrokeStyle(lineWidth: line, lineJoin: .round)).padding(line / 2)
        } else {
            Circle().strokeBorder(color, lineWidth: line)
        }
    }

    @ViewBuilder private func solid(_ color: Color) -> some View {
        if kind == .decision { DiamondShape().fill(color) } else { Circle().fill(color) }
    }
}

/// A diamond with softened corners, filling its square.
struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        let top = CGPoint(x: rect.midX, y: rect.minY), right = CGPoint(x: rect.maxX, y: rect.midY)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY), left = CGPoint(x: rect.minX, y: rect.midY)
        let r = rect.width * 0.12
        var p = Path()
        p.move(to: CGPoint(x: (top.x + left.x) / 2, y: (top.y + left.y) / 2))
        p.addArc(tangent1End: top, tangent2End: right, radius: r)
        p.addArc(tangent1End: right, tangent2End: bottom, radius: r)
        p.addArc(tangent1End: bottom, tangent2End: left, radius: r)
        p.addArc(tangent1End: left, tangent2End: top, radius: r)
        p.closeSubpath()
        return p
    }
}

/// Right half of a disc: "half way there".
private struct HalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: c)
        p.addArc(center: c, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90), endAngle: .degrees(90),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// Right half of a diamond, the decision's "half way there".
private struct HalfDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct PauseBars: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width * 0.32
        var p = Path()
        let corner = CGSize(width: w / 2, height: w / 2)
        p.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), cornerSize: corner)
        p.addRoundedRect(in: CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: rect.height), cornerSize: corner)
        return p
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

private struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

// MARK: - Priority glyph (urgent = a red "!", then 3/2/1 grey bars)

/// The priority picker's marks. Rows show only urgent, as `UrgentMark`; the rest is in the order.
struct PriorityGlyph: View {
    let priority: Priority
    var size: CGFloat = 12

    var body: some View {
        Group {
            if priority == .urgent {
                Bang().fill(Palette.urgent).frame(width: size * 0.2, height: size * 0.8)
            } else {
                Bars(filled: filled).frame(width: size, height: size * 0.84)
            }
        }
        .frame(width: size, height: size)
        .help(L("\(priority.label) priority", "\(priority.label) приоритет"))
    }

    private var filled: Int {
        switch priority {
        case .urgent, .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    private struct Bars: View {
        let filled: Int

        var body: some View {
            GeometryReader { g in
                let w = g.size.width / 4.2
                let gap = (g.size.width - 3 * w) / 2
                ForEach(0..<3, id: \.self) { i in
                    let h = g.size.height * [0.42, 0.71, 1][i]
                    RoundedRectangle(cornerRadius: w / 2.5, style: .continuous)
                        .fill(Color.primary.opacity(i < filled ? 0.62 : 0.16))
                        .frame(width: w, height: h)
                        .offset(x: CGFloat(i) * (w + gap), y: g.size.height - h)
                }
            }
        }
    }

    /// An exclamation mark: a rounded stroke over a dot.
    private struct Bang: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let w = rect.width
            p.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height - w * 1.9),
                             cornerSize: CGSize(width: w / 2, height: w / 2))
            p.addEllipse(in: CGRect(x: rect.minX, y: rect.maxY - w, width: w, height: w))
            return p
        }
    }
}

/// Urgent, on a row: a small red "!" on the facts' baseline, the one priority a row still shows.
struct UrgentMark: View {
    var body: some View {
        Text("!")
            .font(.system(size: 11.5, weight: .heavy))
            .foregroundStyle(Palette.urgent)
            .help(L("Urgent", "Срочно"))
    }
}

// MARK: - Chips and badges

/// New from the last plan and not seen yet: a coral dot in the row's leading margin, like Mail's unread dot.
/// It marks without competing with the title.
struct NewDot: View {
    var body: some View {
        Circle()
            .fill(Palette.coral)
            .frame(width: 5, height: 5)
            .frame(width: 10, height: 10)
            .contentShape(Rectangle())
            .help(L("New: added by Claude in the last plan", "Новая: Claude добавил её в последнем плане"))
    }
}

/// "30m": a row's last fact.
struct EstimateLabel: View {
    let hours: Double

    var body: some View {
        Text(Fmt.estimate(hours))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .help(L("Your time, estimated", "Ваше время (оценка)"))
    }
}

/// A row's day, as plain text: "⚑ Overdue 2d" in red, "⚑ Today" in the sun's color, later days in grey. The
/// flag says deadline, as in Things, so "⚑ Tomorrow" on a Today row never reads as "scheduled for tomorrow".
/// A waiting task's due is the day to check back on it: "↩ Mon 26".
struct DueChip: View {
    let due: Day
    let today: Day
    var check = false

    var body: some View {
        let ahead = today.days(to: due)
        // A check-back day that has come (or gone) is today's business, not a missed deadline.
        let tint: AnyShapeStyle = ahead < 0 && !check ? AnyShapeStyle(Palette.urgent)
            : ahead <= 0 ? AnyShapeStyle(Palette.today) : AnyShapeStyle(.secondary)
        HStack(alignment: .firstTextBaseline, spacing: 2.5) {
            Image(systemName: check ? "arrow.uturn.backward" : "flag.fill").font(.system(size: 8, weight: .semibold))
            Text(Fmt.due(due, today: today, check: check))
        }
        .font(.system(size: 11, weight: ahead <= 0 ? .medium : .regular).monospacedDigit())
        .foregroundStyle(tint)
        .fixedSize()
        .help(Self.help(due: due, ahead: ahead, check: check, today: today))
    }

    private static func help(due: Day, ahead: Int, check: Bool, today: Day) -> String {
        let day = "\(Fmt.longDay(due)) · \(Fmt.relative(due, today: today))"
        return check ? L("Check back \(day)", "Проверить: \(day)")
            : ahead < 0 ? L("Was due \(day)", "Срок прошёл: \(day)") : L("Due \(day)", "Срок: \(day)")
    }
}

/// ▶ — back into the session the task came from: a small grey disc beside a row's hover action.
struct ResumeButton: View {
    let task: TaskItem
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        Button { store.resume(task) } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(hover ? AnyShapeStyle(Palette.coral) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.11 : 0.065)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Resume the session in Terminal", "Продолжить сессию в Терминале"))
    }
}

/// The one quick move a row offers on hover: "Not today" on Today, "Today" elsewhere. A quiet grey capsule
/// that floats over the row's facts.
struct HoverAction: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.primary.opacity(hover ? 0.11 : 0.065)))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A word that acts, in its tint: "Mark done" on Claude's advice. The capsule behind it shows only under
/// the pointer, in padding the button always has, so nothing moves.
struct TextAction: View {
    let title: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(hover ? 0.12 : 0)))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// "▶ Open session": the lead card's way into its session, a quiet line in Claude's color whose ▶ sits in
/// the why's dot column.
struct OpenSessionPill: View {
    let task: TaskItem
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        Button { store.resume(task) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.markGap) {
                Image(systemName: "play.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .frame(width: Metrics.mark)
                Text(L("Open session", "Открыть сессию")).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Palette.coralText)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Palette.coral.opacity(hover ? 0.12 : 0)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.leading, -6)
        .help(L("Resume the session in Terminal", "Продолжить сессию в Терминале"))
    }
}

// MARK: - Pills (a segmented control that needs no menu)

struct PillPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
        var glyph: AnyView? = nil
    }

    let options: [Option]
    let selection: Value?
    /// Less air around each label, for a row that is short of width.
    var tight = false
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                PillButton(option: option, selected: option.value == selection, tight: tight) {
                    onSelect(option.value)
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private struct PillButton: View {
        let option: Option
        let selected: Bool
        let tight: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    if let glyph = option.glyph { glyph }
                    if !option.label.isEmpty { Text(option.label).lineLimit(1).fixedSize() }
                }
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, option.label.isEmpty || tight ? 6 : 8)
                .padding(.vertical, 3.5)
                .background {
                    if selected {
                        Capsule().fill(Color(light: 0xFFFFFF, dark: 0x5A5A5E))
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                    } else if hover {
                        Capsule().fill(Color.primary.opacity(0.06))
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}

// MARK: - Menu pill

/// A compact dropdown in a capsule, "◐ In progress ⌄": a value to change now and then, which shouldn't take a
/// segmented control's width. Live it is a `Menu` drawn with this label as is (button style, plain, no system
/// indicator); `Menu` doesn't draw in ImageRenderer, so debug renders show the label alone — the same pixels.
struct MenuPill<Items: View>: View {
    let title: String
    var glyph: AnyView? = nil
    var help: String = ""
    /// Less air inside the capsule, for a row that is short of width.
    var tight = false
    @ViewBuilder let items: () -> Items
    @Environment(\.rendering) private var rendering
    @State private var hover = false

    var body: some View {
        if rendering {
            label
        } else {
            Menu(content: items) { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { hover = $0 }
                .help(help)
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            if let glyph { glyph }
            Text(title)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Palette.faint)
        }
        .font(.system(size: 11))
        .foregroundStyle(.primary)
        .padding(.leading, (glyph == nil ? 9 : 7) - (tight ? 2 : 0))
        .padding(.trailing, tight ? 6 : 8)
        .frame(height: 24)
        .background(Capsule().fill(Color.primary.opacity(hover ? 0.1 : 0.06)))
        .contentShape(Capsule())
        .fixedSize()
    }
}

// MARK: - Buttons

/// A drawn spinner: ProgressView renders as a placeholder in ImageRenderer, and this one
/// takes the tint of its surroundings.
struct Spinner: View {
    var size: CGFloat = 11
    var lineWidth: CGFloat = 1.8
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.78)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// An icon that acts, 24 pt square, its name in the tooltip: the expanded row's actions. `tint` is the color it
/// takes under the pointer (red for delete).
struct IconButton: View {
    let systemImage: String
    let help: String
    var tint: Color? = nil
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hover ? AnyShapeStyle(tint ?? .primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
