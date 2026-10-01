import AppKit
import FixerCore
import SwiftUI

/// Shared spacing so every block lines up: 24pt page margins, 20pt between sections, 10pt cards.
private enum Layout {
    static let pageInset: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cardRadius: CGFloat = 10
    static let rowInset: CGFloat = 14
    static let rowSpacing: CGFloat = 12
    static let badgeWidth: CGFloat = 88
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmRemove = false
    /// Shown every time the app opens, before anything else can be clicked.
    @State private var showLaunchNotice = true

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            if model.crossOvers.isEmpty {
                NoCrossOverView()
            } else {
                VStack(spacing: Layout.sectionSpacing) {
                    SetupSection()
                    FixesSection()
                    if !model.log.isEmpty { LogSection() }
                }
                .padding(.horizontal, Layout.pageInset)
                .padding(.top, 18)
                .padding(.bottom, 22)
                .disabled(model.isWorking)
                Divider()
                footer
            }
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up bottles or games installed while the app was in the background.
            if !model.isWorking { model.refresh() }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Quit Steam first", isPresented: $model.steamRunningPrompt) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Steam is running in CrossOver. The fixes only work if it's closed first.\n\nMake sure Steam is fully quit out of in your Dock, then click Apply Fixes again.")
        }
        .sheet(item: $model.completedAction) { action in
            DoneSheet(action: action)
                .environmentObject(model)
        }
        .background(
            Color.clear.sheet(isPresented: $showLaunchNotice) { LaunchNoticeSheet() }
        )
        .confirmationDialog("Remove the fixes from “\(model.selectedBottle?.name ?? "")”?", isPresented: $confirmRemove) {
            Button("Remove Fixes", role: .destructive) { model.removeFixes() }
        } message: {
            Text("The DLL copies are removed, and earlier files and DLL overrides are restored.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.hasUndoRecord {
                Button("Remove Fixes…") { confirmRemove = true }
                    .controlSize(.large)
                    .disabled(model.isWorking)
            }
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
                Text(model.workingMessage).foregroundStyle(.secondary)
            }
            Button(model.everythingSelectedIsApplied ? "Apply Again" : "Apply Fixes") { model.apply() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.canApply)
        }
        .padding(.horizontal, Layout.pageInset)
        .padding(.vertical, 14)
    }
}

// MARK: - Building blocks

/// A titled group: small caption above a rounded card, like System Settings.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Layout.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Layout.cardRadius).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, Layout.rowInset)
    }
}

/// A label on the left, its control on the right.
private struct SetupRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            Text(label)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, Layout.rowInset)
        .frame(minHeight: 42)
    }
}

// MARK: - Header

private struct HeaderView: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dungeons II Fixer")
                    .font(.title.weight(.semibold))
                Text("Original fix by Kubas556 · Mac compatibility by [NotProton](https://github.com/NotProtonNot/Dungeons2_macOS_fix)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .tint(Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.pageInset)
        .padding(.top, 22)
    }
}

// MARK: - Setup

private struct SetupSection: View {
    @EnvironmentObject private var model: AppModel
    private let otherTag = AppModel.otherTag

    var body: some View {
        Section(title: "Setup") {
            SetupRow(label: "CrossOver") {
                Picker("CrossOver", selection: $model.selectedCrossOverID) {
                    ForEach(model.crossOvers) { install in
                        Text(install.displayName).tag(Optional(install.id))
                    }
                    Divider()
                    Text("Other…").tag(Optional(otherTag))
                }
                .labelsHidden()
                .fixedSize()
            }
            RowDivider()
            SetupRow(label: "Bottle") {
                if model.bottles.isEmpty {
                    Text("No bottles found").foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseBottlesFolder() }
                } else {
                    Picker("Bottle", selection: $model.selectedBottleID) {
                        ForEach(model.bottles) { bottle in
                            Text(bottle.name).tag(Optional(bottle.id))
                        }
                        Divider()
                        Text("Other…").tag(Optional(otherTag))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh the bottle list")
                .accessibilityLabel("Refresh the bottle list")
            }
            if let bottle = model.selectedBottle {
                RowDivider()
                SetupRow(label: "Minecraft Dungeons II") {
                    if let game = model.game {
                        Label("Found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help(game.root.path)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Button(model.game == nil ? "Choose…" : "Change…") { model.chooseGameFolder() }
                }
                if !bottle.is64Bit {
                    note("This looks like a 32-bit bottle. The game needs a 64-bit (Windows 10) bottle.", warning: true)
                }
                if model.game == nil {
                    note("Install the game with Steam in this bottle, or choose its folder. The C++ runtime fix works without it.")
                }
            }
        }
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Group {
            RowDivider()
            Text(text)
                .font(.callout)
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.rowInset)
                .padding(.vertical, 10)
        }
    }
}

// MARK: - Fixes

private struct FixesSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section(title: "Fixes") {
            ForEach(Array(FixItem.allCases.enumerated()), id: \.element) { index, item in
                if index > 0 { RowDivider() }
                FixRow(item: item, status: model.statuses[item], isOn: binding(for: item))
            }
        }
    }

    private func binding(for item: FixItem) -> Binding<Bool> {
        Binding(
            get: { model.selectedItems.contains(item) },
            set: { on in
                if on { model.selectedItems.insert(item) } else { model.selectedItems.remove(item) }
            }
        )
    }
}

private struct FixRow: View {
    let item: FixItem
    let status: FixStatus?
    @Binding var isOn: Bool

    private var unavailable: Bool { status?.state == .unavailable }

    var body: some View {
        HStack(alignment: .top, spacing: Layout.rowSpacing) {
            Toggle(item.title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(unavailable)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                (Text("Fixes: ").foregroundColor(.secondary).fontWeight(.medium) + Text(item.fixes))
                    .font(.callout)
                Text(item.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Clicking the text also ticks the box; the checkbox handles its own clicks.
            .contentShape(Rectangle())
            .onTapGesture { if !unavailable { isOn.toggle() } }
            if let status { StatusBadge(status: status) }
        }
        .padding(.horizontal, Layout.rowInset)
        .padding(.vertical, 12)
        .opacity(unavailable ? 0.55 : 1)
    }
}

private struct StatusBadge: View {
    let status: FixStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: Layout.badgeWidth)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .help(status.detail)
    }

    private var label: String {
        switch status.state {
        case .applied: return "Applied"
        case .notApplied: return "Not applied"
        case .needsUpdate: return "Update"
        case .unavailable: return "Needs game"
        }
    }

    private var color: Color {
        switch status.state {
        case .applied: return .green
        case .notApplied, .unavailable: return .secondary
        case .needsUpdate: return .orange
        }
    }
}

// MARK: - Log

private struct LogSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded = false

    var body: some View {
        Section(title: "Activity") {
            DisclosureGroup("Details", isExpanded: $expanded) {
                // Scrolls instead of growing, so the window always fits on a laptop screen.
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("Error") ? Color.red : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 110)
                .padding(.top, 6)
            }
            .padding(.horizontal, Layout.rowInset)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Empty state

private struct NoCrossOverView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("CrossOver isn't installed")
                .font(.title3.weight(.semibold))
            Text("Minecraft Dungeons II runs on the Mac through CrossOver. Install it, set up Steam in a bottle, then come back.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            HStack {
                Button("Locate CrossOver…") { model.chooseCrossOver() }
                Link("Get CrossOver", destination: URL(string: "https://www.codeweavers.com/crossover")!)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

// MARK: - Done

private struct DoneSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let action: AppModel.CompletedAction

    private var summary: ApplySummary? {
        if case .applied(let summary) = action { return summary }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(summary == nil ? Color.accentColor : (summary!.changedAnything ? Color.green : Color.secondary))
            Text(summary?.title ?? "Fixes removed")
                .font(.title2.weight(.semibold))

            if let summary {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.entries) { entry in
                        Label {
                            Text(entry.text)
                        } icon: {
                            Image(systemName: entry.alreadyInPlace ? "equal.circle" : "checkmark.circle.fill")
                                .foregroundStyle(entry.alreadyInPlace ? Color.secondary : Color.green)
                        }
                    }
                }
                .frame(maxWidth: 400, alignment: .leading)

                if !summary.nextSteps.isEmpty {
                    Divider().frame(maxWidth: 400)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(summary.nextSteps.enumerated()), id: \.offset) { index, text in
                            step(index + 1, text)
                        }
                    }
                    .frame(maxWidth: 400, alignment: .leading)
                }
            } else {
                Text("The bottle is back the way it was before the fixes.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                if summary?.changedAnything == true {
                    Button("Open CrossOver") {
                        model.openCrossOver()
                        dismiss()
                    }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 480)
    }

    private var icon: String {
        guard let summary else { return "arrow.uturn.backward.circle.fill" }
        return summary.changedAnything ? "checkmark.seal.fill" : "equal.circle.fill"
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Launch notice

private struct LaunchNoticeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text("Important!")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                point("Built with AI", "This app was made with the help of AI. It has been tested by real people, but use it at your own risk.")
                point("Do not contact CodeWeavers support", "CodeWeavers can't support a patched bottle. Only ask them for help with an unpatched one. **Remove Fixes** puts your bottle back the way it was.")
                point("Microsoft sign-in", "The fix uses a community stand-in for Microsoft's Gaming Services. Signing in or playing online is at your own risk.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("I Understand") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private func point(_ title: String, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
