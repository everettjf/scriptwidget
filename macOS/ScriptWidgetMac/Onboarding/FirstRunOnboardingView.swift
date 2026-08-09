//
//  FirstRunOnboardingView.swift
//  ScriptWidgetMac
//

import SwiftUI

enum MacTutorialStep: Int, CaseIterable, Identifiable {
    case welcome
    case create
    case edit
    case preview
    case install

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome to ScriptWidget"
        case .create: "Create your first widget"
        case .edit: "Make it yours"
        case .preview: "Preview every size"
        case .install: "Put it on your desktop"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: "From an idea to a native widget in about five minutes."
        case .create: "Start from a working example—there is nothing to configure first."
        case .edit: "Change JSX with completion, diagnostics, formatting, and AI Copilot."
        case .preview: "Check small, medium, and large layouts before you publish."
        case .install: "Choose the script in macOS Widget Gallery and keep iterating."
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "sparkles.square.filled.on.square"
        case .create: "plus.square.fill"
        case .edit: "chevron.left.forwardslash.chevron.right"
        case .preview: "rectangle.3.group"
        case .install: "rectangle.stack.badge.plus"
        }
    }
}

struct MacOnboardingProgressStore {
    static let currentVersion = 1
    static let completedVersionKey = "scriptwidget.mac.onboarding.completed-version"
    static let currentStepKey = "scriptwidget.mac.onboarding.current-step"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldPresent: Bool {
        defaults.integer(forKey: Self.completedVersionKey) < Self.currentVersion
    }

    var currentStep: MacTutorialStep {
        MacTutorialStep(rawValue: defaults.integer(forKey: Self.currentStepKey)) ?? .welcome
    }

    func save(step: MacTutorialStep) {
        defaults.set(step.rawValue, forKey: Self.currentStepKey)
    }

    func complete() {
        defaults.set(Self.currentVersion, forKey: Self.completedVersionKey)
        defaults.removeObject(forKey: Self.currentStepKey)
    }

    func restart() {
        defaults.set(MacTutorialStep.welcome.rawValue, forKey: Self.currentStepKey)
    }
}

enum MacOnboardingOpenRequest {
    static let notification = Notification.Name("MacOnboardingOpenRequest")
}

struct FirstRunOnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    private let progressStore: MacOnboardingProgressStore
    @State private var step: MacTutorialStep
    @State private var createdWidgetName: String?
    @State private var statusMessage: String?

    init(progressStore: MacOnboardingProgressStore = .init()) {
        self.progressStore = progressStore
        _step = State(initialValue: progressStore.currentStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                stepRail
                Divider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 560, idealHeight: 620)
        .interactiveDismissDisabled()
        .onChange(of: step) { _, newStep in progressStore.save(step: newStep) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Five-Minute Widget")
                    .font(.title3.weight(.semibold))
                Text("Step \(step.rawValue + 1) of \(MacTutorialStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Skip Tutorial") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityHint("Marks onboarding complete. You can reopen it from the Help menu.")
        }
        .padding(16)
    }

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MacTutorialStep.allCases) { item in
                Button {
                    step = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : item.symbol)
                            .frame(width: 22)
                            .foregroundStyle(item.rawValue <= step.rawValue ? Color.accentColor : .secondary)
                        Text(item.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(item == step ? Color.accentColor.opacity(0.12) : .clear)
                    .clipShape(.rect(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(item == step ? "Current step" : "")
            }
            Spacer()
            Text("You can return from Help → Five-Minute Tutorial.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
        .background(Color.secondary.opacity(0.04))
    }

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(step.title, systemImage: step.symbol)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)
                Text(step.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch step {
                case .welcome: welcomeContent
                case .create: createContent
                case .edit: editContent
                case .preview: previewContent
                case .install: installContent
                }
            }
            .padding(36)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            onboardingCallout(icon: "square.grid.2x2", title: "Start with 70 working templates", detail: "Weather, productivity, health, finance, system status, and more.")
            onboardingCallout(icon: "macwindow", title: "Edit and preview together", detail: "The project tree, CodeMirror editor, diagnostics, config, and native preview live in one Studio workspace.")
            onboardingCallout(icon: "iphone.and.arrow.forward", title: "Sync across Apple devices", detail: "Projects use the existing iCloud and App Group storage model for Mac, iPhone, and iPad.")
        }
    }

    private var createContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a small, offline-friendly example. It is a normal project—you can keep it, rename it, or delete it later.")
                .fixedSize(horizontal: false, vertical: true)

            Button {
                createTutorialWidget()
            } label: {
                Label(createdWidgetName == nil ? "Create Tutorial Widget" : "Tutorial Widget Created", systemImage: createdWidgetName == nil ? "plus" : "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(createdWidgetName != nil)

            if let createdWidgetName {
                Label("Created “\(createdWidgetName)”. Select it in the sidebar after the tutorial.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text("Prefer another starting point? Use New from Template at any time, or Generate with AI after configuring a provider.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var editContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingCallout(icon: "sidebar.left", title: "1. Select the project", detail: "Choose your tutorial widget in the Scripts sidebar to open Studio.")
            onboardingCallout(icon: "text.cursor", title: "2. Change one value", detail: "Find “Hello, ScriptWidget!” in main.jsx and replace it with your own text.")
            onboardingCallout(icon: "command", title: "3. Save", detail: "Press ⌘S. Studio preserves cursor and scroll position and refreshes the preview.")
            codeSample
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingCallout(icon: "rectangle.split.3x1", title: "Use the Preview pane", detail: "Switch Family between small, medium, and large. Resize the canvas and inspect runtime output.")
            onboardingCallout(icon: "play.fill", title: "Run before installing", detail: "Press ⌘R after edits. Errors stay visible in Studio instead of silently producing an empty widget.")
            onboardingCallout(icon: "slider.horizontal.3", title: "Use Config for inputs", detail: "Edit display name, parameters, permissions, and Package 2.0 metadata without hand-editing widget.json.")
        }
    }

    private var installContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingCallout(icon: "desktopcomputer", title: "1. Open Widget Gallery", detail: "Control-click the desktop and choose Edit Widgets.")
            onboardingCallout(icon: "magnifyingglass", title: "2. Find ScriptWidget", detail: "Choose a size and drag it onto the desktop or Notification Center.")
            onboardingCallout(icon: "slider.horizontal.3", title: "3. Choose the script", detail: "Control-click the widget, choose Edit ScriptWidget, and select your tutorial project.")
            onboardingCallout(icon: "icloud", title: "4. Let iCloud finish", detail: "If a project is not listed yet, keep ScriptWidget open and use File → Update iCloud Scripts.")
            Text("That’s it. Your project remains editable, and saved changes appear on the next widget refresh.")
                .font(.headline)
                .padding(.top, 4)
        }
    }

    private var codeSample: some View {
        Text("$render(<text font=\"title\">Hello, ScriptWidget!</text>);")
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityLabel("Example JSX code")
    }

    private func onboardingCallout(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Button("Back", systemImage: "chevron.left") { move(by: -1) }
                .disabled(step == .welcome)
            Spacer()
            ProgressView(value: Double(step.rawValue + 1), total: Double(MacTutorialStep.allCases.count))
                .frame(width: 180)
                .accessibilityLabel("Tutorial progress")
                .accessibilityValue("Step \(step.rawValue + 1) of \(MacTutorialStep.allCases.count)")
            Spacer()
            if step == .install {
                Button("Finish", systemImage: "checkmark", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue", systemImage: "chevron.right") { move(by: 1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(16)
    }

    private func move(by offset: Int) {
        let next = min(max(step.rawValue + offset, 0), MacTutorialStep.allCases.count - 1)
        if let value = MacTutorialStep(rawValue: next) { step = value }
    }

    private func createTutorialWidget() {
        let packageName = sharedScriptManager.getValidPackageName(recommendPackageName: "My First Widget")
        let result = sharedScriptManager.saveScript(
            packageName: packageName,
            content: tutorialWidgetSource,
            imageCopyPath: nil
        )
        guard result.0 else {
            statusMessage = result.1
            return
        }
        createdWidgetName = packageName
        NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
    }

    private func finish() {
        progressStore.complete()
        dismiss()
    }
}

let tutorialWidgetSource = """
// Five-Minute Widget — edit the text, press Command-S, then try every preview family.
const family = $getenv("widget-size");

$render(
  <vstack background="#182033" padding="16" corner="18" spacing="8">
    <text font="caption" color="#9FB4FF">MY FIRST WIDGET</text>
    <text font="title" fontWeight="bold" color="#FFFFFF">Hello, ScriptWidget!</text>
    <text font="caption" color="#B8C0D9">Family: {family}</text>
  </vstack>
);
"""
