import AppKit
import Combine
import ClaudoCore
import SwiftUI

@main
@MainActor
enum ClaudoMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// `--board <file>` runs on a fixture: nothing is read from or written to the real data dir. A render
    /// without one reads the real board.json the same way, read-only: `--keep` or `--remove` can't save over it.
    let store = Store(fixture: Args.value("--board").map { URL(fileURLWithPath: $0) }
        ?? (Render.requested ? BoardStore.directory.appendingPathComponent("board.json") : nil))
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug: `Claudo --render <dir> --board <fixture>` writes PNGs and exits (see Render.swift).
        if let dir = Args.value("--render") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Render.run(store: self.store, to: URL(fileURLWithPath: dir))
                NSApp.terminate(nil)
            }
            return
        }

        // `pkill` and launchd's bootout send SIGTERM, which skips applicationWillTerminate:
        // flush the pending save ourselves, then go.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [store] in
            MainActor.assumeIsolated { store.saveNow() }
            exit(0)
        }
        source.resume()
        sigterm = source

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        let host = NSHostingController(rootView: LocalizedRoot().environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateButton() }
            .store(in: &cancellables)

        store.start()
        updateButton()

        if Args.has("--show"), let button = statusItem.button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePopover(button) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A render never writes, whatever its store holds.
        guard !Render.requested else { return }
        store.saveNow()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover.performClose(sender)
            showSettingsMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    func popoverWillShow(_ notification: Notification) { store.popoverWillShow() }
    func popoverDidClose(_ notification: Notification) { store.popoverDidClose() }

    // MARK: Right-click menu

    private func showSettingsMenu() {
        let menu = NSMenu()
        let plan = item(store.running ? L("Planning…", "Планирование…") : L("Plan Now", "Спланировать сейчас")) {
            [store] in store.refresh()
        }
        plan.isEnabled = !store.running
        menu.addItem(plan)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: L("Look Back", "Период")))
        for days in Store.lookbacks {
            let title = L("\(days) Days", plural(days, "", "", ru: ("день", "дня", "дней")))
            menu.addItem(item(title, checked: store.lookback == days) { [store] in store.lookback = days })
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: L("Language", "Язык")))
        for language in AppLanguage.allCases {
            menu.addItem(item(language.title, checked: store.language == language) { [store] in
                store.language = language
            })
        }
        menu.addItem(.separator())
        let hour = "\(Store.morningHour):00"
        let morning = L("Plan Every Morning at \(hour)", "Планировать каждое утро в \(hour)")
        menu.addItem(item(morning, checked: store.autoMorning) { [store] in
            store.autoMorning.toggle()
        })
        if store.persistent {
            menu.addItem(item(L("Launch at Login", "Запускать при входе"), checked: LoginItem.isEnabled) {
                LoginItem.setEnabled(!LoginItem.isEnabled)
            })
            menu.addItem(item(L("Show Data Folder", "Показать папку с данными")) {
                NSWorkspace.shared.open(Paths.support)
            })
        }
        menu.addItem(.separator())
        let quit = item(L("Quit Claudo", "Завершить Claudo")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        // Attach only for this click so a left click keeps opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target   // keeps the target alive
        item.state = checked ? .on : .off
        return item
    }

    // MARK: Tray button

    struct TrayState: Equatable {
        let icon: TrayIcon.State
        let unseen: Bool
        /// Today is still an earlier day's plan: the ball fades and the count greys.
        let stale: Bool
        let title: String
        let tip: String
    }

    private var trayState: TrayState?

    /// Called on every store change (the clock ticks each second), but the button
    /// is only touched when what it shows actually changes.
    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let state = Self.trayState(for: store)
        guard state != trayState else { return }
        trayState = state
        button.image = TrayIcon.image(state.icon, unseen: state.unseen, stale: state.stale)
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        if state.stale { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
        button.attributedTitle = NSAttributedString(string: state.title.isEmpty ? "" : " " + state.title,
                                                    attributes: attributes)
        button.toolTip = state.tip
    }

    /// The ball, the count and the tooltip. "Stale" is `Store.planIsStale`, which a Keep ends for the day.
    static func trayState(for store: Store) -> TrayState {
        let board = store.board
        let open = store.openToday
        let done = store.doneToday
        let stale = store.planIsStale && !store.running
        let carried = store.carriedOver.count
        var tip = ["Claudo"]
        let icon: TrayIcon.State
        if store.running {
            icon = .planning
            tip.append(L("Claude is planning…", "Claude планирует…"))
        } else if board.plannedAt == nil && board.tasks.isEmpty {
            icon = .noPlan
        } else {
            icon = .progress(done: done.count, total: open.count + done.count)
        }
        if stale, let day = board.planDay {
            let plan = Fmt.planName(day, today: Day(store.now))
            let left = carried > 0 ? L(" · \(carried) left", " · осталось \(carried)") : ""
            tip.append("\(plan)\(left) — ✦ " + L("Plan today", "План на сегодня"))
        }
        // Hovering the ball answers "what now": the row Today starts with (a check-in when that's all there is).
        if !store.running, let next = store.todayPlan.lead ?? open.first {
            tip.append(L("Next: ", "Дальше: ") + next.title)
        }
        if !open.isEmpty || !done.isEmpty {
            let total = open.count + done.count
            var line = L("Today: \(done.count) of \(total) done", "Сегодня: сделано \(done.count) из \(total)")
            let hours = Fmt.approx(store.hoursLeftToday)
            if store.hoursLeftToday > 0 { line += L(" · \(hours) left", " · осталось \(hours)") }
            tip.append(line)
        }
        let week = store.weekTasks.count
        if week > 0 { tip.append(L("This week: \(week) more", "Эта неделя: ещё \(week)")) }
        let focus = store.focusAreas.map(\.title)
        if !focus.isEmpty { tip.append(L("Focus: ", "Фокус: ") + focus.joined(separator: ", ")) }
        let unseen = board.unseenCount
        if unseen > 0 { tip.append(L("\(unseen) new from Claude", "Новое от Claude: \(unseen)")) }
        return TrayState(icon: icon, unseen: board.unseenCount > 0 && !store.running, stale: stale,
                         title: open.isEmpty || store.running ? "" : "\(open.count)", tip: tip.joined(separator: "\n"))
    }
}

/// The popover's root: rebuilt whole when the language changes, so no view keeps a word of the old one.
private struct LocalizedRoot: View {
    @EnvironmentObject var store: Store

    var body: some View {
        PopoverView().id(store.language)
    }
}

private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

enum Args {
    static func value(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func has(_ name: String) -> Bool { CommandLine.arguments.contains(name) }
}
