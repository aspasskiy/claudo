import ClaudoCore
import SwiftUI

/// Debug renders: draw the filter's popover open (`--filter-open`), since ImageRenderer can't show a popover.
@MainActor
enum FilterDebug {
    static var panelOpen = false
}

/// The header's filter button: a funnel that turns coral while a filter narrows the list (the chip line under
/// the header says which). A click (or ⌘F) opens the filter's popover. Always 24 × 24, so the tabs never move.
struct FilterButton: View {
    @EnvironmentObject var store: Store
    @State private var open = false
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let active = store.filter.isActive
        Button { open.toggle() } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Palette.coral) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hover || open ? 0.08 : 0)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut("f", modifiers: .command)
        .help(active ? L("Filtered: \(summary) (⌘F)", "Фильтр: \(summary) (⌘F)")
                     : L("Filter by when, area, kind, status or priority (⌘F)",
                         "Фильтр по сроку, проекту, типу, статусу или приоритету (⌘F)"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FilterPanel().environmentObject(store)
        }
    }

    private var summary: String {
        var parts = Store.Horizon.allCases.filter(store.horizons.contains).map(\.title)
        parts += store.filterableAreas.filter { store.filter.areas.contains($0.id) }.map(\.title)
        if let kind = store.filter.kind { parts.append(kind.filterLabel) }
        parts += TaskStatus.filterable.filter(store.filter.statuses.contains).map(\.filterLabel)
        if store.filter.important { parts.append(Self.important) }
        return parts.joined(separator: ", ")
    }

    static var important: String { L("High priority", "Высокий приоритет") }
}

extension TaskStatus {
    /// The statuses the filter offers: work under way, and work on someone else.
    static let filterable: [TaskStatus] = [.doing, .waiting]

    var filterLabel: String {
        switch self {
        case .todo: L("Not started", "Не начато")
        case .doing: L("In progress", "В работе")
        case .waiting: L("Waiting", "Ждёт")
        case .done: L("Done", "Готово")
        case .dropped: L("Dropped", "Отменено")
        }
    }
}

extension TaskKind {
    /// How the filter names a kind: the calls to make, or the work.
    var filterLabel: String {
        switch self {
        case .decision: L("Decisions", "Решения")
        case .task: L("Work", "Работа")
        }
    }
}

// MARK: - The popover

/// The filter's popover: when (Today, This week, Later), which areas to list (any number at once), which kind
/// of task, and only work under way, waiting or important — every part combines with the others. Unlike a
/// menu it stays open while you pick, and every pick shows at once in the counts and the list behind it.
struct FilterPanel: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let areas = store.filterableAreas
        VStack(alignment: .leading, spacing: 0) {
            // "Clear" sits in the heading's own line, and only while a filter is on: no row comes or goes.
            PanelHeading(title: L("When", "Когда")) {
                if store.filter.isActive {
                    ClearLink(title: L("Clear all", "Сбросить всё")) {
                        withAnimation(.snappy(duration: 0.2)) { store.clearFilter() }
                    }
                    .transition(.opacity)
                }
            }
            HStack(spacing: 4) {
                ForEach(Store.Horizon.allCases, id: \.self) { horizon in
                    FlagToggle(title: horizon.title, count: store.listedCount(horizon),
                               on: store.horizons.contains(horizon)) {
                        EmptyView()
                    } action: {
                        withAnimation(.snappy(duration: 0.2)) { store.toggleHorizon(horizon) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 9)
            PanelHeading(title: L("Areas", "Проекты"))
            ForEach(areas) { area in
                AreaToggle(area: area, count: openCount(in: area), on: store.filter.areas.contains(area.id)) {
                    withAnimation(.snappy(duration: 0.2)) { store.toggleFilterArea(area.id) }
                }
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 7)
            PanelHeading(title: L("Show", "Показать"))
            KindPicker(selection: store.filter.kind) { kind in
                withAnimation(.snappy(duration: 0.2)) { store.setFilterKind(kind) }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 9)
            PanelHeading(title: L("Only", "Только"))
            HStack(spacing: 4) {
                ForEach(TaskStatus.filterable, id: \.self) { status in
                    FlagToggle(title: status.filterLabel, on: store.filter.statuses.contains(status)) {
                        StatusGlyph(status: status, size: 9)
                    } action: {
                        withAnimation(.snappy(duration: 0.2)) { store.toggleFilterStatus(status) }
                    }
                }
                FlagToggle(title: FilterButton.important, on: store.filter.important) {
                    Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(Palette.urgent)
                } action: {
                    withAnimation(.snappy(duration: 0.2)) { store.setFilterImportant(!store.filter.important) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        // Russian's "Only" line («В работе», «Ждёт», «Высокий приоритет») needs a little more room.
        .frame(width: Loc.russian ? 324 : 304)
    }

    /// Open rows of the area in the horizons picked that pass the rest of the filter: what picking it would
    /// leave.
    private func openCount(in area: Area) -> Int {
        let known = Set(store.board.areas.map(\.id))
        var rest = store.filter
        rest.areas = []
        let open = (store.shows(.today) ? store.openToday : []) + (store.shows(.week) ? store.weekTasks : [])
            + (store.shows(.later) ? store.laterTasks : [])
        return open.filter { t in
            let home = known.contains(t.area) ? t.area : Area.inboxID
            return home == area.id && rest.passes(t, areas: known)
        }.count
    }
}

private struct PanelHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .frame(height: 18)
        .padding(.bottom, 5)
    }
}

/// An area's own SF symbol in its color: the mark the project view's headers use, so two grey areas (a Mac and
/// the inbox) still look different.
struct SymbolMark: View {
    let area: Area
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: Symbols.valid(area.symbol))
            .font(.system(size: size * 0.85, weight: .semibold))
            .foregroundStyle(area.color.color)
            .frame(width: size + 3, height: size)
    }
}

/// One area in the popover, like a menu item: a checkmark when it is kept, its symbol, its name, its open count.
private struct AreaToggle: View {
    let area: Area
    let count: Int
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.primary)
                    .opacity(on ? 1 : 0)
                    .frame(width: 11)
                SymbolMark(area: area)
                Text(area.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }

    /// What the area is about, its share of the owner's attention, what done looks like this week.
    private var help: String {
        var lines = [area.status.isEmpty ? area.title : "\(area.title): \(area.status)"]
        if let share = area.attention {
            lines.append(L("\(share)% of your attention over the last 7 days",
                           "\(share)% вашего внимания за последние 7 дней"))
        }
        if !area.outcome.isEmpty {
            lines.append(L("Done this week when: \(area.outcome)", "Итог недели: \(area.outcome)"))
        }
        return lines.joined(separator: "\n\n")
    }
}

/// One part of the filter, on or off: an outlined capsule while off, a filled one while on, so several can be
/// on at once and none reads as a segmented control. A horizon's carries its count, as filtered.
private struct FlagToggle<Mark: View>: View {
    let title: String
    var count: Int? = nil
    let on: Bool
    @ViewBuilder var mark: Mark
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                mark
                Text(title).lineLimit(1).fixedSize()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.faint)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(on ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(on ? 0.12 : hover ? 0.05 : 0)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0.14 : 0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// All · Decisions · Work, as a small segmented control: the glyphs are the rows' own (◇ a call, ○ work).
private struct KindPicker: View {
    let selection: TaskKind?
    let onSelect: (TaskKind?) -> Void

    var body: some View {
        HStack(spacing: 1) {
            segment(nil, L("All", "Все"))
            segment(.decision, TaskKind.decision.filterLabel)
            segment(.task, TaskKind.task.filterLabel)
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func segment(_ kind: TaskKind?, _ title: String) -> some View {
        Segment(kind: kind, title: title, selected: selection == kind) { onSelect(kind) }
    }

    private struct Segment: View {
        let kind: TaskKind?
        let title: String
        let selected: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let kind { KindMark(kind: kind, size: 8) }
                    Text(title)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
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

/// A neutral ◇ or ○: the kind of row, without the status colors the rows give it.
private struct KindMark: View {
    let kind: TaskKind
    var size: CGFloat = 8

    var body: some View {
        Group {
            if kind == .decision {
                DiamondShape().stroke(style: StrokeStyle(lineWidth: 1.2, lineJoin: .round)).padding(0.6)
            } else {
                Circle().strokeBorder(lineWidth: 1.2)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The popover drawn open in a render: a floating card under the filter button, as AppKit would show it.
struct FilterPanelPreview: View {
    var body: some View {
        FilterPanel()
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(light: 0xF6F6F7, dark: 0x323234))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

// MARK: - Chips

/// What the filter keeps, under the header while it is on: "Today ×  ● Atlas ×  ◇ Decisions ×  ◐ In progress ×
/// … Clear". One line; area chips that don't fit fold into "+2", and when even that is too long the priority,
/// status and kind chips, last first, keep only their marks (the horizon chips always show in full).
struct FilterChips: View {
    @EnvironmentObject var store: Store

    private struct Chip: Identifiable {
        let id: String
        let title: String
        let mark: AnyView
        let remove: () -> Void
    }

    var body: some View {
        let areas = areaChips
        let when = whenChips
        let kind = flagChips
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                ForEach(Self.fits(areas: areas.count, flags: kind.count), id: \.self) { fit in
                    switch fit {
                    case .areas(let shown):
                        row(when: when, Array(areas.prefix(shown)), folded: Array(areas.dropFirst(shown)), kind: kind)
                    case .compact(let compact):
                        row(when: when, [], folded: areas, kind: kind, compact: compact)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ClearLink { withAnimation(.snappy(duration: 0.2)) { store.clearFilter() } }
        }
        // Chips are containers on the 8 pt edge, their first mark on the 18 pt text edge; "Clear" ends on it.
        .padding(.leading, Metrics.listInset)
        .padding(.trailing, Metrics.listInset + Metrics.rowInset)
        .frame(height: Metrics.chipRowHeight)
    }

    /// One way to lay the line out: `areas(n)` shows the first n area chips and folds the rest into "+N";
    /// `compact(n)` folds every area and draws the last n flag chips as marks alone.
    enum Fit: Hashable {
        case areas(Int)
        case compact(Int)
    }

    /// The layouts ViewThatFits tries, longest first. Each is a value of its own: ViewThatFits traps on two
    /// candidates with one id ("child view IDs must be unique"), as two ranges of Ints would give.
    static func fits(areas: Int, flags: Int) -> [Fit] {
        stride(from: areas, through: 0, by: -1).map(Fit.areas) + (1...max(1, flags)).map(Fit.compact)
    }

    private func row(when: [Chip], _ shown: [Chip], folded: [Chip], kind: [Chip], compact: Int = 0) -> some View {
        HStack(spacing: 5) {
            ForEach(when) { chip in
                ChipView(title: chip.title, mark: chip.mark, action: chip.remove)
            }
            ForEach(shown) { chip in
                ChipView(title: chip.title, mark: chip.mark, action: chip.remove)
            }
            if !folded.isEmpty {
                Text("+\(folded.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.faint)
                    .padding(.horizontal, 3)
                    .help(folded.map(\.title).joined(separator: ", "))
            }
            ForEach(Array(kind.enumerated()), id: \.element.id) { index, chip in
                ChipView(title: chip.title, mark: chip.mark, compact: index >= kind.count - compact,
                         action: chip.remove)
            }
        }
        .fixedSize()
    }

    private var areaChips: [Chip] {
        var chips = store.filterableAreas.filter { store.filter.areas.contains($0.id) }.map { area in
            Chip(id: area.id, title: area.title, mark: AnyView(SymbolMark(area: area, size: 10))) {
                withAnimation(.snappy(duration: 0.2)) { store.toggleFilterArea(area.id) }
            }
        }
        // An area the board no longer has can't be picked again, but still filters: it gets a chip to remove it.
        let known = Set(store.filterableAreas.map(\.id))
        for id in store.filter.areas.subtracting(known).sorted() {
            chips.append(Chip(id: id, title: store.board.area(id)?.title ?? id,
                              mark: AnyView(Image(systemName: "folder").font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Palette.quiet))) {
                withAnimation(.snappy(duration: 0.2)) { store.toggleFilterArea(id) }
            })
        }
        return chips
    }

    /// Today, This week, Later as picked, in that order.
    private var whenChips: [Chip] {
        Store.Horizon.allCases.filter(store.horizons.contains).map { horizon in
            Chip(id: "when-\(horizon)", title: horizon.title, mark: AnyView(EmptyView())) {
                withAnimation(.snappy(duration: 0.2)) { store.toggleHorizon(horizon) }
            }
        }
    }

    /// The kind, statuses and priority picked, in the panel's order.
    private var flagChips: [Chip] {
        var chips: [Chip] = []
        if let kind = store.filter.kind {
            chips.append(Chip(id: "kind", title: kind.filterLabel,
                              mark: AnyView(KindMark(kind: kind, size: 8).foregroundStyle(.secondary))) {
                withAnimation(.snappy(duration: 0.2)) { store.setFilterKind(nil) }
            })
        }
        for status in TaskStatus.filterable where store.filter.statuses.contains(status) {
            chips.append(Chip(id: "status-\(status.rawValue)", title: status.filterLabel,
                              mark: AnyView(StatusGlyph(status: status, size: 8))) {
                withAnimation(.snappy(duration: 0.2)) { store.toggleFilterStatus(status) }
            })
        }
        if store.filter.important {
            chips.append(Chip(id: "important", title: FilterButton.important,
                              mark: AnyView(Text("!").font(.system(size: 9.5, weight: .heavy))
                                .foregroundStyle(Palette.urgent))) {
                withAnimation(.snappy(duration: 0.2)) { store.setFilterImportant(false) }
            })
        }
        return chips
    }
}

/// A removable chip: a click anywhere on it removes that part of the filter.
private struct ChipView: View {
    let title: String
    let mark: AnyView
    /// The mark alone, the title in the tooltip: for a line too long to hold every word.
    var compact = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                mark
                if !compact {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 130, alignment: .leading)
                        .fixedSize()
                }
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(hover ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.faint))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.leading, Metrics.rowInset)
            .padding(.trailing, 7)
            .frame(height: 20)
            .background(Capsule().fill(Color.primary.opacity(hover ? 0.1 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(compact ? L("\(title): click to remove it from the filter", "\(title): нажмите, чтобы убрать из фильтра")
                      : L("Remove \(title) from the filter", "Убрать «\(title)» из фильтра"))
    }
}

private struct ClearLink: View {
    var title = L("Clear", "Сбросить")
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Show everything again", "Снова показать всё"))
        .fixedSize()
    }
}
