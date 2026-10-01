import Foundation

/// What an "Apply Fixes" run actually did, in words the completion screen can show.
public struct ApplySummary: Equatable {
    public struct Entry: Equatable, Identifiable {
        public let item: FixItem
        /// True when the fix was already in place, so nothing was changed for it.
        public let alreadyInPlace: Bool
        public var id: FixItem { item }

        public var text: String {
            if alreadyInPlace {
                return "\(item.title): already in place"
            }
            switch item {
            case .gamingServices: return "Gaming Services fix: xgameruntime.dll installed and set to native"
            case .cppRuntime: return "C++ runtime fix: \(FixEngine.cppRuntimeDLLs.count) overrides set"
            }
        }
    }

    public let entries: [Entry]
    public let bottleName: String

    /// - Parameters:
    ///   - applied: the fixes that were run.
    ///   - before: their status before the run.
    public init(applied: Set<FixItem>, before: [FixItem: FixStatus], bottleName: String) {
        self.entries = FixItem.allCases.filter(applied.contains).map {
            Entry(item: $0, alreadyInPlace: before[$0]?.state == .applied)
        }
        self.bottleName = bottleName
    }

    public var changedAnything: Bool { entries.contains { !$0.alreadyInPlace } }
    private var changed: Set<FixItem> { Set(entries.filter { !$0.alreadyInPlace }.map(\.item)) }

    public var title: String { changedAnything ? "You're all set" : "Nothing to change" }

    /// The Gaming Services stand-in can pop up a Microsoft sign-in window. On Steam the game
    /// doesn't need it, so it's only mentioned, as optional, when the stand-in was just installed.
    public var mentionsSignIn: Bool { changed.contains(.gamingServices) }

    public var nextSteps: [String] {
        guard changedAnything else { return [] }
        var steps = [
            "Open CrossOver and run Steam from the “\(bottleName)” bottle.",
            "Start Minecraft Dungeons II.",
        ]
        if mentionsSignIn {
            steps.append("A Microsoft sign-in window may pop up. You don't need it to play on Steam, so you can ignore it.")
        }
        return steps
    }
}
