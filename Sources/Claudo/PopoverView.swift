import AppKit
import ClaudoCore
import SwiftUI

/// The popover, one size whatever it shows: the horizon chips on top, the one list in a fixed frame that
/// scrolls, the status bar at the bottom. Nothing grows, so a chip, expanding a row or an undo never resizes
/// the popover or moves what is under the pointer. A filter's chip line takes its room from the list.
struct PopoverView: View {
    /// Debug renders (`--full`): the list at its full height instead of the fixed frame, to review long tabs.
    var fullList = false
    @EnvironmentObject var store: Store
    @Environment(\.rendering) private var rendering
    /// Set by "✓ 31 this week": the list scrolls to "Done this week" at its end.
    @State private var scrollToEnd = false

    var body: some View {
        let board = store.board
        let empty = board.tasks.isEmpty && board.areas.isEmpty
        let chips = store.filter.isActive && !empty
        VStack(spacing: 0) {
            Header(empty: empty)
            if chips {
                FilterChips().transition(.opacity)
            }
            ZStack(alignment: .top) {
                if empty {
                    if store.running {
                        Skeleton().transition(.opacity)
                    } else {
                        EmptyBoard().transition(.opacity)
                    }
                } else {
                    list.id(ListID(horizons: store.horizons, grouping: store.grouping)).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: fullList ? nil : Metrics.listHeight - (chips ? Metrics.chipRowHeight : 0), alignment: .top)
            .clipped()
            .mask(EdgeFade())
            .overlay(alignment: .top) { Divider() }
            StatusBar(showWeekDone: showWeekDone)
        }
        .frame(width: Metrics.popoverWidth, height: fullList ? nil : Metrics.popoverHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if rendering, FilterDebug.panelOpen {
                FilterPanelPreview()
                    .padding(.top, Metrics.headerHeight - 4)
                    .padding(.trailing, 10)
            }
        }
        .animation(.snappy(duration: 0.2), value: chips)
        .animation(.easeInOut(duration: 0.2), value: empty)
    }

    private static let end = "list-end"

    /// A new chip or a new view swaps the list whole, cross-faded, scrolled back to the top.
    private struct ListID: Hashable {
        let horizons: Set<Store.Horizon>
        let grouping: Store.Grouping
    }

    /// The list, scrolling in its fixed frame. A render can't draw a ScrollView: it lays the list out at full
    /// height and lets the frame cut it, as the popover's first screen would.
    @ViewBuilder private var list: some View {
        if rendering {
            BoardList().fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        BoardList()
                        // Room to scroll the last row clear of the bottom fade.
                        Color.clear.frame(height: EdgeFade.height).id(Self.end)
                    }
                }
                .scrollIndicators(.automatic)
                .onChange(of: scrollToEnd) { _, go in
                    guard go else { return }
                    scrollToEnd = false
                    withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
    }

    /// "✓ 31 this week": "Done this week" open at the end of the list, scrolled down to it.
    private func showWeekDone() {
        withAnimation(.snappy(duration: 0.22)) {
            store.showAllHorizons()
            store.showDone = true
        }
        // Let the opened fold lay out before scrolling to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { scrollToEnd = true }
    }
}

/// The list's bottom edge fades out over a few points, so a row cut by the status bar reads as "more below"
/// rather than as a clipped line of text.
private struct EdgeFade: View {
    static let height: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.height)
        }
    }
}

// MARK: - Header

/// The list's three views as tabs — Schedule (Today, This week, Later), Projects, Priority — then the filter
/// and +. The same rows in every view: Today, This week and Later are the filter's first part, not tabs. No
/// brand and no date: the menu-bar icon is the brand, and Today's group says the date.
private struct Header: View {
    let empty: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Store.Grouping.allCases.enumerated()), id: \.element) { index, grouping in
                tab(grouping, key: KeyEquivalent(Character("\(index + 1)")))
            }
            Spacer(minLength: 8)
            FilterButton()
                .disabled(empty)
            HeaderIconButton(systemImage: "plus", help: L("New task (⌘N)", "Новая задача (⌘N)")) {
                withAnimation(.snappy(duration: 0.2)) { store.startAdding() }
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        // Containers on the popover's 8 pt edge; the first tab's words on the 18 pt text edge.
        .padding(.horizontal, Metrics.listInset)
        .frame(height: Metrics.headerHeight)
    }

    private func tab(_ grouping: Store.Grouping, key: KeyEquivalent) -> some View {
        ViewTab(title: grouping.title, symbol: grouping.symbol, on: store.grouping == grouping) {
            withAnimation(.snappy(duration: 0.22)) { store.setGrouping(grouping) }
        }
        .keyboardShortcut(key, modifiers: .command)
        .disabled(empty)
        .help("\(grouping.title): \(grouping.help) (⌘\(String(key.character)))")
    }
}

/// A view's tab: a symbol and plain secondary words, the current one primary in a filled capsule. The weight
/// never changes, so switching moves no title.
private struct ViewTab: View {
    let title: String
    let symbol: String
    let on: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(on || hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            // The capsule on the 8 pt edge, the symbol on the 18 pt one.
            .padding(.horizontal, Metrics.rowInset)
            .frame(height: 26)
            .background(Capsule().fill(Color.primary.opacity(on ? 0.09 : hover ? 0.045 : 0)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0.1 : 0), lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The header's 24 × 24 icon buttons; the hover fill is a background, so nothing changes size.
private struct HeaderIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Empty and loading

/// No board yet: what Claudo does in two lines and the one thing to do about it, centered in the list's
/// frame, so the first plan landing changes the middle of the popover and not its size.
private struct EmptyBoard: View {
    @EnvironmentObject var store: Store

    /// The tray's ball, wound neat: nothing open yet.
    static let ball: NSImage = {
        let image = TrayIcon.image(.noPlan, unseen: false)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.05)).frame(width: 64, height: 64)
                    Image(nsImage: Self.ball)
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 31, height: 26)
                        .foregroundStyle(.secondary)
                }
                Text(L("Your board is empty", "Доска пуста"))
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 16)
                Text(L("Claude reads your last \(store.lookback) days of Claude Code sessions\n"
                       + "and sorts your work into Today, This week and Later.",
                       "Claude читает ваши сессии Claude Code за \(StatusBar.days(store.lookback))\n"
                       + "и раскладывает работу: Сегодня, Эта неделя, Позже."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize()
                    .padding(.top, 6)
                PlanWithClaude()
                    .padding(.top, 18)
                AddYourself()
                    .padding(.top, 10)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(store.adding == nil ? 1 : 0.35)

            if let target = store.adding {
                QuickAddRow(target: target)
                    .padding(.horizontal, Metrics.listInset)
                    .padding(.top, 8)
            }
        }
    }
}

/// The empty board's one call to action. ⌘R lives on the status bar, whose plan button it stands in for.
private struct PlanWithClaude: View {
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        Button { store.refresh() } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11.5, weight: .semibold))
                Text(L("Plan with Claude", "Спланировать с Claude")).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(Palette.coral.opacity(hover ? 0.88 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Ask Claude for a plan from the last \(store.lookback) days of sessions (⌘R)",
                "Попросить у Claude план по сессиям за \(StatusBar.days(store.lookback)) (⌘R)"))
    }
}

private struct AddYourself: View {
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { store.startAdding() }
        } label: {
            Text(L("or add a task yourself", "или добавьте задачу сами"))
                .font(.system(size: 11.5))
                .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("New task (⌘N)", "Новая задача (⌘N)"))
    }
}

/// Placeholder rows while the first plan is being made; the status bar says what Claude is doing.
private struct Skeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<5, id: \.self) { i in
                HStack(alignment: .top, spacing: Metrics.gutter) {
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1.5).frame(width: 15, height: 15)
                        .frame(width: Metrics.glyph)
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(Color.primary.opacity(0.09)).frame(width: [230, 180, 250, 160, 205][i], height: 9)
                        Capsule().fill(Color.primary.opacity(0.055)).frame(width: [150, 110, 170, 90, 130][i], height: 7)
                    }
                    .padding(.top, 3)
                }
            }
        }
        .padding(.horizontal, Metrics.listInset + Metrics.rowInset)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(pulse ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}
