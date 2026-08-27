//
//  WidgetRowView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/6.
//

import SwiftUI


struct WidgetRowImageView: View {
    let model: ScriptModel
    
    var body: some View {
        NameAutoImageView(name: model.name, colors: getGradientColorsWithString(string: model.name), size: 46)
    }
}

struct WidgetRowTextView: View {
    let model: ScriptModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Text(model.summary ?? "JavaScript widget")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}


/// Small iCloud status indicator shown when a script's main file isn't available
/// locally — so the user understands why a widget might be downloading or stale,
/// instead of seeing only a generic widget error (issue #6).
struct ICloudStatusBadge: View {
    let model: ScriptModel
    @State private var state: ICloudItemState = .downloaded

    var body: some View {
        Group {
            switch state {
            case .downloading:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloading from iCloud")
            case .notInICloud:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Not available in iCloud")
            case .error:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.red)
                    .accessibilityLabel("iCloud error")
            case .local, .downloaded:
                EmptyView()
            }
        }
        .font(.footnote)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let package = model.package
        DispatchQueue.global(qos: .utility).async {
            let resolved = package.mainFileICloudState()
            DispatchQueue.main.async { self.state = resolved }
        }
    }
}

struct WidgetRowView: View {
    let model: ScriptModel

    var body: some View {
        HStack(spacing: 12) {
            WidgetRowImageView(model: model)
            WidgetRowTextView(model: model)
            Spacer()
            ICloudStatusBadge(model: model)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Widget Row") {
    WidgetRowView(model: ScriptModel(package: ScriptWidgetPackage(bundle: "Script", relativePath: "template/is-friday")))
        .padding()
}

#Preview("Widget Row · Dark") {
    WidgetRowView(model: ScriptModel(package: ScriptWidgetPackage(bundle: "Script", relativePath: "template/is-friday")))
        .preferredColorScheme(.dark)
        .padding()
}
