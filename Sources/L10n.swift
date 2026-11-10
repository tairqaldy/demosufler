import Foundation

/// Interface language. English is the default, Russian can be picked in setup or settings.
enum Lang: String, CaseIterable {
    case en, ru

    static var current: Lang = .en

    var title: String { self == .en ? "English" : "Русский" }
}

/// Returns the English or the Russian text, depending on the current interface language.
func tr(_ en: String, _ ru: String) -> String {
    Lang.current == .ru ? ru : en
}
