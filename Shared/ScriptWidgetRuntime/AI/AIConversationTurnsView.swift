//
//  AIConversationTurnsView.swift
//  ScriptWidget
//
//  The turns of an AI conversation, one under the other: the request, what
//  came of it, the version it made, and what to do when it did not work.
//  Used by the AI window and the editor's Copilot panel on the Mac, and by
//  the AI screen on iPhone and iPad.
//

import SwiftUI

struct AIConversationTurnsView: View {
    @ObservedObject var session: AIConversationSession
    /// False when no provider is set up or the widget can not be changed.
    let canSend: Bool
    /// Shows a piece of code with a title.
    let showCode: (String, String) -> Void

    var body: some View {
        ForEach(session.conversation.turns) { turn in
            if turn.isManualEdit == true {
                manualEdit(turn)
                    .id(turn.id)
            } else {
                turnView(turn)
                    .id(turn.id)
            }
        }
    }

    private func manualEdit(_ turn: AIConversationTurn) -> some View {
        // Two lines: side by side they do not fit the editor's narrow panel.
        VStack(alignment: .leading, spacing: 3) {
            Label("Code from the editor", systemImage: "pencil.line")
                .font(.caption)
                .foregroundStyle(.secondary)
            versionLine(turn)
        }
        .opacity(turn.isAbandoned ? 0.5 : 1)
    }

    @ViewBuilder
    private func turnView(_ turn: AIConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.request)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: StudioDesign.cardCornerRadius))
            }
            VStack(alignment: .leading, spacing: 6) {
                turnOutcome(turn)
                if turn.usage.totalTokens > 0 {
                    Text("\(turn.usage.totalTokens) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(turn.isAbandoned ? 0.5 : 1)
    }

    @ViewBuilder
    private func turnOutcome(_ turn: AIConversationTurn) -> some View {
        switch turn.status {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(activityText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", systemImage: "stop.circle") { session.cancel() }
                    .controlSize(.small)
                    .keyboardShortcut(".", modifiers: .command)
            }
            if !session.liveText.isEmpty {
                Text(Self.tail(of: session.liveText, lines: 8))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(8, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Self.codeBackground.opacity(0.6), in: .rect(cornerRadius: 6))
                    .accessibilityLabel("Code being written")
            }
        case .succeeded:
            Text(turn.note ?? "Done.")
                .textSelection(.enabled)
            if turn.repairs > 0 {
                Label("Fixed automatically \(turn.repairs) time\(turn.repairs == 1 ? "" : "s")", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            versionLine(turn)
        case .unconverged:
            Label("This change did not run, so the widget was left as it was.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let error = turn.errorSummary {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack {
                retryButton(turn, title: "Try Again")
                if let code = turn.failedSource, !code.isEmpty {
                    Button("Show Its Code") { showCode("Code That Did Not Run", code) }
                        .controlSize(.small)
                }
            }
        case .failed:
            Label(turn.errorSummary ?? "The AI provider could not complete the request.", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.red)
                .textSelection(.enabled)
            retryButton(turn, title: "Retry")
        case .cancelled:
            Label("Stopped.", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
            retryButton(turn, title: "Send Again")
        case .interrupted:
            Label("Interrupted when the app closed.", systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
            retryButton(turn, title: "Send Again")
        }
    }

    @ViewBuilder
    private func versionLine(_ turn: AIConversationTurn) -> some View {
        if let version = session.conversation.version(turn.versionID) {
            let isCurrent = version.id == session.conversation.currentVersionID
            HStack(spacing: 8) {
                Label("Version \(version.number)", systemImage: isCurrent ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                if isCurrent {
                    Text("shown now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Go to This Version") { session.selectVersion(version.id) }
                        #if os(macOS)
                        .buttonStyle(.link)
                        #else
                        .buttonStyle(.borderless)
                        #endif
                        .font(.caption)
                        .disabled(session.isRunning)
                }
                if turn.isAbandoned {
                    Text("left behind")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func retryButton(_ turn: AIConversationTurn, title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "arrow.clockwise") { session.retry(turnID: turn.id) }
            .controlSize(.small)
            .disabled(session.isRunning || !canSend)
    }

    private var activityText: String {
        switch session.activity {
        case .idle: return ""
        case .thinking: return "Writing the widget…"
        case .running: return "Running it…"
        case .repairing(let attempt, _): return "It did not run. Fixing, attempt \(attempt) of \(AIConversationLimits.maxAttemptsPerTurn)…"
        }
    }

    private static var codeBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    private static func tail(of text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
