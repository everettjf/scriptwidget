//
//  SidebarWidgetRowView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/15.
//

import SwiftUI


struct WidgetRowImageView: View {
    var model: ScriptModel
    
    var body: some View {
        NameAutoImageView(name: model.name, colors: getGradientColorsWithString(string: model.name), size: 20)
    }
}

struct WidgetRowTextView: View {
    var model: ScriptModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.name)
        }
        .frame(height:20)
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
                    .foregroundColor(.secondary)
                    .help("Downloading from iCloud")
            case .notInICloud:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundColor(.orange)
                    .help("Not available offline — open while online to sync")
            case .error:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundColor(.red)
                    .help("iCloud download error")
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

    var model: ScriptModel

    var body: some View {
        HStack {
            WidgetRowImageView(model: model)
            WidgetRowTextView(model: model)
            Spacer()
            ICloudStatusBadge(model: model)
        }
    }
}

struct WidgetRowView_Previews: PreviewProvider {
    static var previews: some View {
        WidgetRowView(model: ScriptModel(package: ScriptWidgetPackage(bundle: "Script", relativePath: "template/is-friday")))
            .previewLayout(.sizeThatFits)
            .padding()
        
        
        WidgetRowView(model: ScriptModel(package: ScriptWidgetPackage(bundle: "Script", relativePath: "template/is-friday")))
            .preferredColorScheme(.dark)
            .previewLayout(.sizeThatFits)
            .padding()
        
    }
}
