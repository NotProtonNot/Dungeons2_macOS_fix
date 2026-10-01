import AppKit
import FixerCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var crossOvers: [CrossOverInstall] = []
    @Published private(set) var bottles: [Bottle] = []
    @Published private(set) var game: GameInstall?
    @Published private(set) var statuses: [FixItem: FixStatus] = [:]
    @Published private(set) var hasUndoRecord = false
    @Published private(set) var isWorking = false
    @Published private(set) var workingMessage = ""
    @Published private(set) var log: [String] = []
    @Published var selectedItems = Set(FixItem.allCases)
    @Published var errorMessage: String?
    /// Steam is open in CrossOver; the fixes must wait until it's quit.
    @Published var steamRunningPrompt = false
    @Published var completedAction: CompletedAction?

    enum CompletedAction: Identifiable {
        case applied(ApplySummary)
        case removed

        var id: String {
            switch self {
            case .applied: return "applied"
            case .removed: return "removed"
            }
        }
    }

    /// Picker tag for the "Other…" item that opens a file chooser.
    nonisolated static let otherTag = "__other__"

    @Published var selectedCrossOverID: String? {
        didSet {
            if selectedCrossOverID == Self.otherTag {
                selectedCrossOverID = oldValue
                DispatchQueue.main.async { self.chooseCrossOver() }
                return
            }
            guard selectedCrossOverID != oldValue else { return }
            defaults.set(selectedCrossOverID, forKey: Keys.crossOver)
        }
    }

    @Published var selectedBottleID: String? {
        didSet {
            if selectedBottleID == Self.otherTag {
                selectedBottleID = oldValue
                DispatchQueue.main.async { self.chooseBottlesFolder() }
                return
            }
            guard selectedBottleID != oldValue else { return }
            defaults.set(selectedBottleID, forKey: Keys.bottle)
            recentOverrides = nil
            loadBottle()
        }
    }

    var selectedCrossOver: CrossOverInstall? { crossOvers.first { $0.id == selectedCrossOverID } }
    var selectedBottle: Bottle? { bottles.first { $0.id == selectedBottleID } }

    /// The DLL shipped inside the app.
    let payload: URL? = Bundle.main.url(forResource: "xgameruntime", withExtension: "dll")
        ?? ProcessInfo.processInfo.environment["DUNGEONS_FIXER_DLL"].map { URL(fileURLWithPath: $0) }

    private let defaults = UserDefaults.standard
    private let store = ManifestStore.standard
    /// Overrides as Wine reported them after our last change, and user.reg's date at that moment.
    /// Wine writes user.reg a few seconds after it finishes, so until the file changes these are the truth.
    private var recentOverrides: (values: [String: String], registryDate: Date?)?

    private enum Keys {
        static let crossOver = "selectedCrossOver"
        static let bottle = "selectedBottle"
        static let extraCrossOvers = "extraCrossOverApps"
        static let extraBottleFolders = "extraBottleFolders"
        static let gameFolders = "gameFolderByBottle"
    }

    // MARK: Discovery

    func refresh() {
        let picked = stringArray(Keys.extraCrossOvers).map { URL(fileURLWithPath: $0) }
        crossOvers = CrossOverLocator.find(additional: picked)
        if selectedCrossOver == nil {
            let saved = defaults.string(forKey: Keys.crossOver)
            selectedCrossOverID = crossOvers.first { $0.id == saved }?.id ?? crossOvers.first?.id
        }

        var folders = [BottleLocator.defaultDirectory]
        if let prefs = UserDefaults(suiteName: CrossOverLocator.bundleIdentifier)?.dictionaryRepresentation() {
            folders += BottleLocator.directories(fromPreferences: prefs)
        }
        folders += stringArray(Keys.extraBottleFolders).map { URL(fileURLWithPath: $0, isDirectory: true) }
        bottles = BottleLocator.bottles(in: folders)

        if selectedBottle == nil {
            let saved = defaults.string(forKey: Keys.bottle)
            let preferred = bottles.first { $0.id == saved }
                ?? bottles.first { GameLocator.locate(in: $0) != nil }
                ?? bottles.first { $0.name.localizedCaseInsensitiveContains("steam") }
                ?? bottles.first
            selectedBottleID = preferred?.id
        } else {
            loadBottle()
        }
        if selectedBottle == nil { loadBottle() }
    }

    private func loadBottle() {
        guard let bottle = selectedBottle else {
            game = nil
            statuses = [:]
            hasUndoRecord = false
            return
        }
        let saved = (defaults.dictionary(forKey: Keys.gameFolders) as? [String: String])?[bottle.id]
        game = saved.flatMap { GameLocator.validate(URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? GameLocator.locate(in: bottle)
        refreshStatus()
    }

    func refreshStatus() {
        guard let engine = makeEngine() else {
            statuses = [:]
            return
        }
        var overrides = engine.registry.storedOverrides()
        if let recent = recentOverrides {
            if registryDate(of: engine.bottle) == recent.registryDate {
                overrides = recent.values
            } else {
                recentOverrides = nil
            }
        }
        statuses = engine.status(overrides: overrides)
        hasUndoRecord = engine.manifest.map { !$0.isEmpty } ?? false
    }

    private func registryDate(of bottle: Bottle) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: bottle.userRegistry.path))?[.modificationDate] as? Date
    }

    private func makeEngine() -> FixEngine? {
        guard let bottle = selectedBottle else { return nil }
        let payload = self.payload ?? URL(fileURLWithPath: "/nonexistent/\(FixEngine.dllName)")
        let engine = FixEngine(bottle: bottle, game: game, crossOver: selectedCrossOver, payload: payload, store: store)
        engine.expectedHash = Bundle.main.object(forInfoDictionaryKey: "XGameRuntimeSHA256") as? String
        return engine
    }

    // MARK: Choosing things by hand

    func chooseCrossOver() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose your copy of CrossOver."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let install = CrossOverInstall(appURL: url) else {
            errorMessage = "\(url.lastPathComponent) isn't CrossOver."
            return
        }
        appendUnique(install.appURL.path, to: Keys.extraCrossOvers)
        refresh()
        selectedCrossOverID = install.id
    }

    func chooseBottlesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a bottle, or the folder that holds your CrossOver bottles."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = BottleLocator.isBottle(url) ? url.deletingLastPathComponent() : url
        guard !BottleLocator.bottles(in: [folder]).isEmpty else {
            errorMessage = "No CrossOver bottles were found in \(url.lastPathComponent)."
            return
        }
        appendUnique(folder.path, to: Keys.extraBottleFolders)
        refresh()
        if BottleLocator.isBottle(url) { selectedBottleID = Bottle(url: url).id }
    }

    func chooseGameFolder() {
        guard let bottle = selectedBottle else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = GameLocator.steamLibraries(in: bottle).first?
            .appendingPathComponent("steamapps/common", isDirectory: true) ?? bottle.driveC
        panel.message = "Choose the Minecraft Dungeons II folder (the one with Dungeons.exe)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let found = GameLocator.validate(url, searchNearby: true) else {
            errorMessage = "That folder doesn't contain Minecraft Dungeons II. Choose the folder that holds Dungeons.exe."
            return
        }
        var map = (defaults.dictionary(forKey: Keys.gameFolders) as? [String: String]) ?? [:]
        map[bottle.id] = found.root.path
        defaults.set(map, forKey: Keys.gameFolders)
        game = found
        refreshStatus()
    }

    private func stringArray(_ key: String) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    private func appendUnique(_ value: String, to key: String) {
        var values = stringArray(key)
        if !values.contains(value) { values.append(value) }
        defaults.set(values, forKey: key)
    }

    // MARK: Actions

    /// Fixes that are ticked and can actually run.
    var runnableItems: Set<FixItem> {
        selectedItems.filter { statuses[$0]?.state != .unavailable }
    }

    var everythingSelectedIsApplied: Bool {
        !runnableItems.isEmpty && runnableItems.allSatisfy { statuses[$0]?.state == .applied }
    }

    var canApply: Bool {
        !isWorking && selectedBottle != nil && !runnableItems.isEmpty
    }

    func apply() {
        guard !Processes.isSteamRunning() else {
            steamRunningPrompt = true
            return
        }
        let items = runnableItems
        let summary = ApplySummary(applied: items, before: statuses, bottleName: selectedBottle?.name ?? "")
        run(message: "Applying fixes…", success: .applied(summary)) { @Sendable engine in
            try engine.apply(items)
        }
    }

    func removeFixes() {
        run(message: "Removing fixes…", success: .removed) { @Sendable engine in
            try engine.undo()
        }
    }

    private func run(message: String, success: CompletedAction,
                     _ work: @escaping @Sendable (FixEngine) throws -> [String: String]) {
        guard !isWorking, let engine = makeEngine() else { return }
        isWorking = true
        workingMessage = message
        log.removeAll()
        engine.log = { @Sendable [weak self] line in
            Task { @MainActor in self?.log.append(line) }
        }
        // File copies and Wine can take a few seconds; keep the window responsive.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try work(engine) }
            await self?.finish(result, success: success)
        }
    }

    private func finish(_ result: Result<[String: String], Error>, success: CompletedAction) {
        isWorking = false
        switch result {
        case .success(let overrides):
            recentOverrides = selectedBottle.map { (overrides, registryDate(of: $0)) }
            completedAction = success
        case .failure(let error):
            log.append("Error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        refreshStatus()
    }

    func openCrossOver() {
        guard let app = selectedCrossOver?.appURL else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
