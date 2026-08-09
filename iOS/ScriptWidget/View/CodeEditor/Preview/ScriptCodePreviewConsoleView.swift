//
//  ScriptCodePreviewConsoleView.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/9/10.
//

import SwiftUI
import Combine


struct ScriptCodePreviewConsoleOutput : Identifiable {
    let id = UUID()
    let data: String
}

class ScriptCodePreviewConsoleDataObject : ObservableObject {
    public static let addLogNotification = Notification.Name("ScriptCodePreviewConsoleDataObject_addLog")
    
    @Published var consoleOutputs : [ScriptCodePreviewConsoleOutput] = []
    var cancellables = [Cancellable]()
    
    init() {
        let cancellableAddLog = NotificationCenter.default.publisher(for: Self.addLogNotification)
            .sink { [weak self](notification) in
                guard let log = notification.object as? String else {
                    return
                }
                if log == "$START" {
                    self?.consoleOutputs.removeAll()
                }
                self?.consoleOutputs.append(ScriptCodePreviewConsoleOutput(data: log))
            }
        self.cancellables.append(cancellableAddLog)
        print("PreviewView console object init :\(Unmanaged.passUnretained(self).toOpaque())")
    }
    
    deinit {
        print("PreviewView console object deinit :\(Unmanaged.passUnretained(self).toOpaque())")
        for cancellable in self.cancellables {
            cancellable.cancel()
        }
    }
    
    static func addLog(_ log: String) {
        NotificationCenter.default.post(name: Self.addLogNotification, object: log)
    }
}

struct ScriptCodePreviewConsoleView : View {
    @ObservedObject var data:ScriptCodePreviewConsoleDataObject
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(data.consoleOutputs.count) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy All", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = data.consoleOutputs.map(\.data).joined(separator: "\n")
                }
                .disabled(data.consoleOutputs.isEmpty)
                Button("Clear", systemImage: "trash") {
                    data.consoleOutputs.removeAll()
                }
                .disabled(data.consoleOutputs.isEmpty)
            }
            List {
                ForEach(data.consoleOutputs) { item in
                    Text(item.data)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("Copy") { UIPasteboard.general.string = item.data }
                        }
                }
            }
        }
    }
}


//struct ScriptCodePreviewConsoleView_Previews: PreviewProvider {
//    static var previews: some View {
//        ScriptCodePreviewConsoleView()
//    }
//}
