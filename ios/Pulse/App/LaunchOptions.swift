import Foundation

/// Launch arguments used by the automated screenshot job (.github/workflows/ios.yml), e.g.
///   xcrun simctl launch <device> dev.pulse.app -hasSeenWelcome YES -screenshotTab sleep
/// UserDefaults exposes `-key value` launch arguments automatically. These only pick which
/// screen opens first; they never change data. Ignored in normal use (the keys are never set).
enum LaunchOptions {
    /// "today" | "sleep" | "activity" | "trends"
    static var tab: String? { UserDefaults.standard.string(forKey: "screenshotTab") }
    /// On the Today tab: "recovery" (push the Recovery screen) | "settings" (open the Settings
    /// sheet) | "explainer" (open a metric sheet). On the Activity tab: "workout" (open a workout).
    static var route: String? { UserDefaults.standard.string(forKey: "screenshotRoute") }
    /// "bottom" (start scrolled to the end, to capture the lower half of a long screen)
    static var scroll: String? { UserDefaults.standard.string(forKey: "screenshotScroll") }
}
