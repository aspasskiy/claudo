import AppKit
import ClaudoCore
import SwiftUI

/// Debug renders for reviewing the UI without the menu bar:
///
///     Claudo --render <dir> --board <fixture.json> [--appearance light|dark] [--language en|ru]
///            [--scope today,week,later]
///            [--planned-ago <hours>] [--sessions-since <n>] [--expand <task id>] [--hover <task id>]
///            [--state <state>] [--show-done] [--show-later]
///            [--show-focus] [--keep] [--adding]
///            [--rename <task id>] [--remove <task id>] [--name <file name>]
///            [--filter-area <id,id>] [--filter-kind decision|task] [--filter-status doing,waiting]
///            [--filter-important] [--filter-open] [--full] [--group date|project|priority]
///
/// `--state` sets what the status bar shows: `error` (`--error <text>` for another message), `undo` (removes Today's first row; `--remove <id>` picks
/// one), `running` (reading sessions), `summarizing`, `planning`, `planned` or `result` (the run's summary),
/// `stale` (yesterday's plan, 11 sessions since), `replan` (today's plan, 11 sessions since), `never` (tasks
/// but no plan yet) and `empty` (no board at all; add `--running` for the first plan's skeleton).
/// `--filter-open` draws the filter's popover open; `--full` lays the list out at full height instead of the
/// popover's fixed frame.
///
/// Writes <dir>/<name>.png (default "<state or scopes>-<appearance>", "list" with no chip on, "-ru" after it in
/// Russian) and <dir>/tray-<appearance>.png, and prints the list's content height against its fixed height
/// ("fits" = no scrolling on the first screen).
/// Fixture dates are shifted so the board reads as planned `--planned-ago` hours ago (2 by default;
/// 18 makes it yesterday's plan); its calendar days (due, plannedFor…) move by the same number of days.
/// Without `--board` it draws the real board.json, read into a store that never saves.
@MainActor
enum Render {
    /// `--render <dir>` is on the command line: nothing may be written but the PNGs.
    static var requested: Bool { Args.value("--render") != nil }

    static func run(store: Store, to dir: URL) {
        // The interface's language first, as the menu would have set it before the popover opened.
        store.language = Args.value("--language") == "ru" ? .russian : .english
        let look = Args.value("--appearance") ?? "light"
        let dark = look == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let state = Args.value("--state")
        // A stale plan is yesterday's whatever the hour: 14:00 the day before.
        let sinceMidnight = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date())) / 3600
        let hoursAgo = Args.value("--planned-ago").flatMap(Double.init) ?? (state == "stale" ? sinceMidnight + 10 : 2)
        if let planned = store.board.plannedAt {
            store.replaceBoard(store.board.shifted(by: Date().addingTimeInterval(-hoursAgo * 3600).timeIntervalSince(planned)))
        }
        if state == "empty" { store.replaceBoard(.empty) }
        if state == "never" {
            var board = store.board
            board.plannedAt = nil
            store.replaceBoard(board)
        }
        if state == "running" || (state == "empty" && Args.has("--running")) { store.simulateRun(startedSecondsAgo: 23) }
        if state == "summarizing" { store.simulateRun(startedSecondsAgo: 87, stage: .summarizing(done: 2, total: 7)) }
        if state == "planning" { store.simulateRun(startedSecondsAgo: 154, stage: .planning(sessions: 412)) }
        if state == "error" {
            // `--error <text>` draws another failure as the planner would word it.
            store.simulateError(Args.value("--error")
                ?? "claude exited 1: Claude usage limit reached — your limit resets at 18:00. Try again later.")
        }
        if state == "planned" || state == "result" {
            var summary = Merge.Summary()
            summary.added = 2
            summary.closed = 1
            summary.advised = 1
            store.showPlanSummary(summary)
        }
        // `--scope today,week` turns those chips on. None: the whole list.
        for name in (Args.value("--scope") ?? "").split(separator: ",") {
            switch name {
            case "today": store.toggleHorizon(.today)
            case "week": store.toggleHorizon(.week)
            case "later": store.toggleHorizon(.later)
            default: break
            }
        }
        // `--group project|priority`: the list's other views.
        if let grouping = Args.value("--group").flatMap(Store.Grouping.init(rawValue:)) { store.setGrouping(grouping) }
        if Args.has("--keep") { store.keepForToday() }
        // `--filter-area atlas,lumen` and `--filter-kind decision|task` narrow the lists as the filter menu would.
        for id in (Args.value("--filter-area") ?? "").split(separator: ",") { store.toggleFilterArea(String(id)) }
        if let kind = Args.value("--filter-kind").flatMap(TaskKind.init(rawValue:)) { store.setFilterKind(kind) }
        for name in (Args.value("--filter-status") ?? "").split(separator: ",") {
            if let status = TaskStatus(rawValue: String(name)) { store.toggleFilterStatus(status) }
        }
        if Args.has("--filter-important") { store.setFilterImportant(true) }
        if let id = Args.value("--expand") { store.expanded = id }
        if let id = Args.value("--hover") { store.debugHover = id }
        if Args.has("--show-done") { store.showDone = true }
        if Args.has("--show-later") { store.showLater = true }
        if Args.has("--show-focus") { store.showFocus = true }
        if Args.has("--adding") { store.startAdding() }
        if let id = Args.value("--remove") ?? (state == "undo" ? store.listedTodayPlan.lead?.id : nil) { store.remove(id) }
        FilterDebug.panelOpen = Args.has("--filter-open")
        if let id = Args.value("--rename") { store.expanded = id; store.editing = id }
        store.popoverWillShow()
        // A fixture has no sessions of its own: the count is whatever the review needs.
        store.simulateSessionsSincePlan(Args.value("--sessions-since").flatMap(Int.init)
            ?? (state == "stale" || state == "replan" ? 11 : nil))

        let scopes = Store.Horizon.allCases.filter { store.horizons.contains($0) }.map { "\($0)" }
        let tabName = (store.grouping == .date ? "" : "\(store.grouping)-") + (scopes.isEmpty ? "list" : scopes.joined(separator: "+"))
        let suffix = store.language == .russian ? "-ru" : ""
        let name = Args.value("--name") ?? "\(state ?? tabName)-\(look)\(suffix)"
        popover(store: store, dark: dark, to: dir.appendingPathComponent("\(name).png"))
        tray(dark: dark, to: dir.appendingPathComponent("tray-\(look).png"))
        // What the tray's tooltip would say for this board.
        print("\(name): tray \"\(AppDelegate.trayState(for: store).tip.replacingOccurrences(of: "\n", with: " | "))\"")
        if let height = contentHeight(store: store, dark: dark) {
            let cap = Metrics.listHeight - (store.filter.isActive ? Metrics.chipRowHeight : 0)
            print("\(name): \(tabName) content \(Int(height.rounded())) pt, list \(Int(cap))"
                  + (height <= cap ? " (fits)" : " (scrolls \(Int((height - cap).rounded())) pt)"))
        }
    }

    /// The list laid out in full, as the popover's scroll view would hold it.
    private static func contentHeight(store: Store, dark: Bool) -> CGFloat? {
        let view = BoardList()
            .frame(width: Metrics.popoverWidth)
            .environmentObject(store)
            .environment(\.rendering, true)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.cgImage.map { CGFloat($0.height) }
    }

    /// ImageRenderer can't see the popover's material, so a flat background stands in.
    private static func popover(store: Store, dark: Bool, to url: URL) {
        let background = dark ? Color(red: 0.165, green: 0.165, blue: 0.175) : Color(red: 0.945, green: 0.945, blue: 0.95)
        let view = PopoverView(fullList: Args.has("--full"))
            .environmentObject(store)
            .environment(\.rendering, true)
            .background(background)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Every tray state on menu-bar-like strips at 1x and 2x, magnified with no smoothing so the pixels
    /// compare one for one.
    private static func tray(dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let rows: [(Int, String)] = [(1, "1x"), (2, "2x")]
        let strips = rows.map { strip(scale: $0.0, appearance: appearance, dark: dark) }
        guard let first = strips.first ?? nil else { return }
        let zoom: CGFloat = 4
        let label: CGFloat = 26
        let stripSize = NSSize(width: CGFloat(first.width) * zoom, height: CGFloat(first.height) * zoom)
        let size = NSSize(width: stripSize.width, height: CGFloat(rows.count) * (stripSize.height + label))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        (dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 1, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        ctx.interpolationQuality = .none
        for (i, strip) in strips.enumerated() {
            guard let strip else { continue }
            let y = size.height - CGFloat(i + 1) * (stripSize.height + label)
            // Every strip is drawn 4 points wide per menu-bar point: 1x pixels come out 4×4, 2x pixels 2×2.
            let scale = CGFloat(strip.width) / CGFloat(first.width)
            ctx.draw(strip, in: CGRect(x: 0, y: y, width: CGFloat(strip.width) * zoom / scale,
                                       height: CGFloat(strip.height) * zoom / scale))
            NSAttributedString(string: rows[i].1, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: dark ? NSColor(white: 0.75, alpha: 1) : NSColor(white: 0.35, alpha: 1),
            ]).draw(at: NSPoint(x: 10, y: y + stripSize.height + 4))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// One menu-bar strip (24 pt tall) rendered at `scale` pixels per point.
    private static func strip(scale: Int, appearance: NSAppearance, dark: Bool) -> CGImage? {
        // (state, unseen, stale, title)
        let states: [(TrayIcon.State, Bool, Bool, String)] = [
            (.noPlan, false, false, ""),
            (.progress(done: 0, total: 7), false, false, "7"),
            (.progress(done: 0, total: 5), false, false, "5"),
            (.progress(done: 2, total: 5), true, false, "3"),
            (.progress(done: 3, total: 5), false, false, "2"),
            (.progress(done: 4, total: 5), false, false, "1"),
            (.progress(done: 5, total: 5), false, false, ""),
            (.planning, false, false, ""),
            (.progress(done: 2, total: 5), false, true, "3"),
        ]
        let cell: CGFloat = 44
        let size = NSSize(width: cell * CGFloat(states.count) + 12, height: 24)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            for (i, (state, unseen, stale, title)) in states.enumerated() {
                let x = 10 + CGFloat(i) * cell
                // Each icon goes through its own transparency layer so its dot cut-out
                // clears only the icon, not the strip behind it.
                let ctx = NSGraphicsContext.current!.cgContext
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                let icon = TrayIcon.image(state, unseen: unseen, stale: stale)
                let frame = NSRect(x: x, y: (size.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height)
                if icon.isTemplate {
                    NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r)
                        NSColor.labelColor.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }.draw(in: frame)
                } else {
                    icon.draw(in: frame)
                }
                ctx.endTransparencyLayer()
                if !title.isEmpty {
                    NSAttributedString(string: " " + title, attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    ]).draw(at: NSPoint(x: x + icon.size.width, y: 4))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}

extension Board {
    /// Every date moved by `delta`, and every calendar day by as many days as the plan's day moved, so
    /// a fixture keeps its meaning: due "the Monday after the plan" stays that Monday, and a row snoozed
    /// "until tomorrow" stays off Today.
    func shifted(by delta: TimeInterval) -> Board {
        var b = self
        let days = plannedAt.map { Day($0).days(to: Day($0.addingTimeInterval(delta))) } ?? Int((delta / 86400).rounded())
        b.plannedAt = plannedAt?.addingTimeInterval(delta)
        b.keptOn = keptOn?.adding(days: days)
        b.tasks = tasks.map { t in
            var t = t
            t.createdAt = t.createdAt.addingTimeInterval(delta)
            t.updatedAt = t.updatedAt.addingTimeInterval(delta)
            t.completedAt = t.completedAt?.addingTimeInterval(delta)
            t.due = t.due?.adding(days: days)
            t.plannedFor = t.plannedFor?.adding(days: days)
            t.todaySince = t.todaySince?.adding(days: days)
            t.whenSetOn = t.whenSetOn?.adding(days: days)
            t.snoozedUntil = t.snoozedUntil?.adding(days: days)
            return t
        }
        return b
    }
}
