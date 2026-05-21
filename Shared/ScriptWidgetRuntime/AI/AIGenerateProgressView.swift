//
//  AIGenerateProgressView.swift
//  ScriptWidget
//
//  Live status + history for the agent loop.
//

import SwiftUI

struct AIGenerateProgressView: View {
    @ObservedObject var session: AIGenerateSession

    @State private var historyExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            phaseHeader

            if let progress = progressFraction {
                ProgressView(value: progress)
                    .tint(tintForPhase)
            }

            if let detail = detailLine {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                Label("\(session.usage.totalTokens) tokens", systemImage: "bolt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.isRunning {
                    Button(role: .destructive) {
                        session.cancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !session.iterationHistory.isEmpty {
                DisclosureGroup(isExpanded: $historyExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.iterationHistory) { record in
                            HStack(alignment: .top, spacing: 8) {
                                Text("#\(record.iteration)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .leading)
                                if let err = record.errorSummary {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .font(.caption2)
                                    Text(err)
                                        .font(.caption2)
                                        .lineLimit(2)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption2)
                                    Text("ran successfully")
                                        .font(.caption2)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    Text("History (\(session.iterationHistory.count))")
                        .font(.footnote)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    // MARK: - derived

    private var phaseHeader: some View {
        HStack(spacing: 8) {
            icon
                .font(.title3)
                .foregroundStyle(tintForPhase)
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    @ViewBuilder private var icon: some View {
        switch session.phase {
        case .idle:            Image(systemName: "sparkles")
        case .thinking:        Image(systemName: "brain")
        case .running:         Image(systemName: "play.circle")
        case .fixing:          Image(systemName: "wrench.and.screwdriver")
        case .done:            Image(systemName: "checkmark.seal.fill")
        case .exhausted:       Image(systemName: "exclamationmark.triangle")
        case .failed:          Image(systemName: "xmark.octagon.fill")
        case .cancelled:       Image(systemName: "xmark.circle")
        }
    }

    private var title: String {
        let limit = session.maxIterationsForProgress
        switch session.phase {
        case .idle: return "Ready"
        case .thinking(let i): return "Thinking (iteration \(i) / \(limit))"
        case .running(let i): return "Running (iteration \(i) / \(limit))"
        case .fixing(let i, _): return "Fixing (iteration \(i) / \(limit))"
        case .done: return "Done"
        case .exhausted: return "Did not converge"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var detailLine: String? {
        switch session.phase {
        case .fixing(_, let summary): return summary
        case .failed(let msg): return msg
        case .exhausted(_, let lastError): return lastError
        case .running: return "Executing generated JSX inside the sandbox runtime."
        case .thinking: return "Waiting on the model response."
        default: return nil
        }
    }

    private var progressFraction: Double? {
        let limit = Double(session.maxIterationsForProgress)
        guard limit > 0 else { return nil }
        let i = Double(session.currentIteration)
        switch session.phase {
        case .thinking, .running, .fixing:
            return Swift.min(1.0, i / limit)
        case .done: return 1.0
        case .exhausted: return 1.0
        default: return nil
        }
    }

    private var tintForPhase: Color {
        switch session.phase {
        case .done: return .green
        case .failed, .exhausted: return .orange
        case .cancelled: return .gray
        default: return .accentColor
        }
    }
}
