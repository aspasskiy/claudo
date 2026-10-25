@testable import ClaudoCore
@testable import Claudo
import XCTest

/// The interface in English or Russian: counts with the right noun form, the language the menu picks, and the
/// words the rows and the status bar print in Russian.
final class LocalizationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Loc.russian = true
    }

    override func tearDown() {
        Loc.russian = false
        super.tearDown()
    }

    private func sessions(_ n: Int) -> String {
        plural(n, "session", "sessions", ru: ("сессия", "сессии", "сессий"))
    }

    func testRussianCountsTakeOneOfThreeForms() {
        XCTAssertEqual(sessions(1), "1 сессия")
        XCTAssertEqual(sessions(2), "2 сессии")
        XCTAssertEqual(sessions(5), "5 сессий")
        XCTAssertEqual(sessions(11), "11 сессий", "11–14 take the many form whatever their last digit")
        XCTAssertEqual(sessions(21), "21 сессия")
        XCTAssertEqual(sessions(22), "22 сессии")
        XCTAssertEqual(sessions(25), "25 сессий")
        XCTAssertEqual(sessions(111), "111 сессий")
        XCTAssertEqual(sessions(0), "0 сессий")
    }

    func testEnglishCountsHaveTwoForms() {
        Loc.russian = false
        XCTAssertEqual(sessions(1), "1 session")
        XCTAssertEqual(sessions(2), "2 sessions")
        XCTAssertEqual(sessions(21), "21 sessions")
        XCTAssertEqual(sessions(0), "0 sessions")
    }

    func testTheMenusLanguageResolves() {
        XCTAssertFalse(AppLanguage.english.isRussian)
        XCTAssertTrue(AppLanguage.russian.isRussian)
        XCTAssertEqual(AppLanguage.system.isRussian, Locale.preferredLanguages.first?.hasPrefix("ru") ?? false)
        XCTAssertEqual(AppLanguage.english.planLanguage, "English")
        XCTAssertEqual(AppLanguage.russian.planLanguage, "Russian")
        XCTAssertEqual(AppLanguage.system.planLanguage, PlanLanguage.system)
        XCTAssertEqual(AppLanguage(rawValue: "russian"), .russian, "the menu's pick is kept by its raw value")
        XCTAssertEqual(AppLanguage.english.title, "English")
        XCTAssertEqual(AppLanguage.russian.title, "Русский", "each language in its own words")
        XCTAssertEqual(AppLanguage.system.title, "Как в системе")
    }

    @MainActor func testTheStoresLanguageSwitchesTheInterface() {
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(store.language, .english, "a fixture reads the same on any Mac")
        XCTAssertFalse(Loc.russian)
        store.language = .russian
        XCTAssertTrue(Loc.russian)
        XCTAssertEqual(When.week.label, "Эта неделя")
        store.language = .english
        XCTAssertEqual(When.week.label, "This Week")
    }

    func testRussianWords() {
        let d = Day(year: 2026, month: 10, day: 24)
        XCTAssertEqual(Fmt.due(d, today: d, check: false), "Сегодня")
        XCTAssertEqual(Fmt.due(d.adding(days: 1), today: d, check: false), "Завтра")
        // The system capitalizes a weekday that starts the text, or not, by its version.
        XCTAssertEqual(Fmt.due(d.adding(days: 2), today: d, check: false).lowercased(), "пн, 26")
        XCTAssertEqual(Fmt.due(d.adding(days: -2), today: d, check: false), "2 дн. назад")
        XCTAssertEqual(Fmt.relative(d.adding(days: 5), today: d), "через 5 дней")
        XCTAssertEqual(Fmt.relative(d.adding(days: -2), today: d), "2 дня назад")
        XCTAssertEqual(Fmt.estimate(0.25), "15 мин")
        XCTAssertEqual(Fmt.estimate(2.5), "2,5 ч")
        XCTAssertEqual(Fmt.approx(4), "≈4 ч")
        XCTAssertEqual(Fmt.count(3, "session"), "3 сессии")
        XCTAssertEqual(Fmt.count(21, "day"), "21 день")
        XCTAssertEqual(Fmt.planName(d.adding(days: -1), today: d), "План от пятницы")
        XCTAssertEqual(Fmt.planDay(d.adding(days: -1), today: d), "пятницы", "for \"из плана от пятницы\"")
        XCTAssertEqual(Fmt.failure("claude exited 1: Claude AI usage limit reached"), "Достигнут лимит Claude")
    }

    func testRussianPlannedIsRelativeToday() {
        let cal = Calendar.current
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let now = date(25, 14, 30)
        XCTAssertEqual(Fmt.planned(date(25, 14, 30), now: now), "План: только что")
        XCTAssertEqual(Fmt.planned(date(25, 12, 20), now: now), "План: 2 ч назад")
        XCTAssertEqual(Fmt.planned(date(24, 16, 12), now: now), "План: вчера в 16:12")
        XCTAssertEqual(Fmt.planned(date(23, 16, 12), now: now), "План: пт, 16:12", "lowercase mid-sentence")
        XCTAssertEqual(Fmt.day(date(25, 9)), "вс, 25 окт.")
    }

    /// Every failure the planner can report reads in Russian; one it doesn't know keeps Claude's words after a
    /// Russian lead (the raw text is the tooltip).
    func testRussianFailures() {
        XCTAssertEqual(Fmt.failure("No Claude sessions in the last 30 days"), "Нет сессий Claude за последние 30 дней")
        XCTAssertEqual(Fmt.failure("No Claude sessions in the last 21 days"), "Нет сессий Claude за последние 21 день")
        XCTAssertEqual(Fmt.failure("claude didn't answer in 15 min"), "Claude не ответил за 15 мин")
        XCTAssertEqual(Fmt.failure("Haiku returned no summaries"), "Haiku не вернул сводки")
        XCTAssertEqual(Fmt.failure("claude returned no plan: (no result)"), "Claude не вернул план")
        XCTAssertEqual(Fmt.failure("claude returned no summaries: x"), "Claude не вернул сводки")
        XCTAssertEqual(Fmt.failure("claude exited 2: network unreachable\nat line 3"),
                       "Claude завершился с ошибкой: network unreachable")
        XCTAssertEqual(Fmt.failure("claude: overloaded"), "Claude завершился с ошибкой: overloaded")
        XCTAssertEqual(Fmt.failure("claude exited 1: "), "Claude завершился с ошибкой")
        Loc.russian = false
        XCTAssertEqual(Fmt.failure("claude didn't answer in 15 min"), "Claude didn't answer in 15 min")
        XCTAssertEqual(Fmt.failure("claude returned no plan: (no result)"), "Claude returned no plan")
        XCTAssertEqual(Fmt.failure("claude returned no summaries: x"), "Claude returned no summaries")
        XCTAssertEqual(Fmt.failure("Sonnet returned no summaries"), "Sonnet returned no summaries")
    }

    /// The inbox is the one area the interface names: in its language, wherever an area's name shows.
    @MainActor func testTheInboxIsNamedInTheInterfacesLanguage() {
        XCTAssertEqual(Area.inbox.title, "Входящие")
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        store.language = .russian
        store.toggleFilterArea(Area.inboxID)
        store.toggleFilterStatus(.doing)
        XCTAssertEqual(store.nothingListed("на этой неделе"), "Для входящих на этой неделе ничего в работе нет")
        store.setFilterImportant(true)
        XCTAssertEqual(store.nothingListed("на сегодня", left: true),
                       "Для входящих на сегодня ничего важного в работе не осталось")
        store.setFilterKind(.decision)
        XCTAssertEqual(store.nothingListed("на сегодня"), "Для входящих на сегодня нет важных решений в работе")
        store.language = .english
        XCTAssertEqual(Area.inbox.title, "Inbox")
    }

    /// What the store says stays what happened until it is shown: a switch of language rewords it.
    @MainActor func testTheStoresMessagesFollowASwitch() {
        let store = Store(fixture: URL(fileURLWithPath: "/dev/null"))
        var summary = Merge.Summary()
        summary.added = 2
        store.showPlanSummary(summary)
        store.refresh()
        XCTAssertEqual(store.planNotice?.text, "2 new")
        XCTAssertEqual(store.error, "Planning is off for a fixture board")
        XCTAssertFalse(store.errorIsPlanFailure)
        store.language = .russian
        XCTAssertEqual(store.planNotice?.text, "новых: 2")
        XCTAssertEqual(store.error, "Для тестовой доски планирование выключено")
        store.simulateError("claude: overloaded")
        XCTAssertTrue(store.errorIsPlanFailure)
        XCTAssertEqual(store.error, "claude: overloaded", "a failed run keeps the planner's words for the tooltip")
        store.language = .english
    }

    /// A formatter made in one language never answers in it after a switch.
    func testDatesFollowASwitch() {
        let d = Day(year: 2026, month: 10, day: 24)
        let russian = Fmt.due(d.adding(days: 68), today: d, check: false)
        Loc.russian = false
        XCTAssertEqual(Fmt.due(d.adding(days: 68), today: d, check: false), "31 Dec")
        Loc.russian = true
        XCTAssertEqual(Fmt.due(d.adding(days: 68), today: d, check: false), russian)
        XCTAssertNotEqual(russian, "31 Dec")
    }
}
