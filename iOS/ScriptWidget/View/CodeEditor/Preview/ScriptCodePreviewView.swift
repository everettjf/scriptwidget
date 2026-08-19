//
//  ScriptCodeRunnerView.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/30.
//

import SwiftUI
struct ScriptCodePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @SceneStorage("preview-size-type") private var widgetSizeType = 0
    
    @State private var isDebugMode = false
    @State private var showAlert = false
    @State private var showAlertMessage = ""
    
    @State private var scriptParameter = ""
    @State private var scriptParameterApplied = ""
    @State private var widgetRenderingMode = "fullColor"
    @State private var outputTab = 0
    @FocusState private var scriptParameterIsFocused: Bool
    
    @StateObject private var consoleData = ScriptCodePreviewConsoleDataObject()
  
    @StateObject private var state: ScriptCodePreviewDataObject
    
    @Binding var filePath: URL
    let showsCloseButton: Bool
    
    init(model: ScriptModel, filePath: Binding<URL>, showsCloseButton: Bool = true) {
//        print("PreviewView init model-id: \(model.id)  file-path: \(filePath.wrappedValue)")
        
        _filePath = filePath
        _state = StateObject(wrappedValue: ScriptCodePreviewDataObject(model: model, filePath: filePath.wrappedValue, widgetSizeType: 0, scriptParameter: ""))
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        content
            .alert(isPresented: $showAlert) { () -> Alert in
                Alert(title: Text(self.showAlertMessage))
            }
    }
    
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            
            ScriptPackageHorizontalFileView(model: state.model, currentFilePath: state.filePath) { file in
                // preview refresh
                print("change file : \(file.name)")
                self.filePath = file.path
                state.changeFile(file.path)
            }
            .padding(.bottom, 5)
            
            Group {
                if widgetSizeType == 7 {
                    ScriptCodeAllSizesPreview(
                        model: state.model,
                        filePath: state.filePath,
                        scriptParameter: scriptParameterApplied,
                        widgetRenderingMode: widgetRenderingMode,
                        isDebugMode: isDebugMode
                    )
                } else {
                    ZStack {
                        Color(.secondarySystemGroupedBackground)
                        preview
                    }
                    .frame(minHeight: WidgetSizeHelper.size(Int32(widgetSizeType)).height + 48)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(previewSizeLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            
            Form {
                Section("Config") {
                    config
                }
                Section {
                    Picker("Output", selection: $outputTab) {
                        Text("Problems").tag(0)
                        Text("Console").tag(1)
                    }
                    .pickerStyle(.segmented)

                    if outputTab == 0 {
                        if let problem = state.lastErrorMessage {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } else {
                            Label("No runtime problems", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ScriptCodePreviewConsoleView(data: consoleData)
                            .frame(minHeight: 120)
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
            .formStyle(.grouped)
        }
    }
    
    var header: some View {
        HStack {
            Spacer()
            
            VStack(spacing: 2) {
                Text("Widget Preview")
                    .font(.headline)
                Text(state.previewStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if showsCloseButton {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
    
    var preview: some View {
        ScriptWidgetElementView(
            element: state.rootElement,
            context: ScriptWidgetElementContext(
                runtime: state.runtime,
                debugMode: isDebugMode,
                scriptName: state.model.package.name,
                scriptParameter: self.scriptParameterApplied,
                package: state.model.package
            )
        )
        .frame(
            width: WidgetSizeHelper.size(Int32(self.widgetSizeType)).width,
            height: WidgetSizeHelper.size(Int32(self.widgetSizeType)).height
        )
        .background(Color(.systemBackground))
        .clipShape(.rect(cornerRadius: widgetSizeType == 5 ? (WidgetSizeHelper.size(Int32(widgetSizeType)).height / 2) : 16))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
    }
    
    
    
    var config: some View {
        Group {
            Picker(selection: $widgetSizeType, label: Label("Preview Size", systemImage: "rectangle.resize")) {
                Text("Small").tag(0)
                Text("Medium").tag(1)
                Text("Large").tag(2)
                Text("ExtraLarge").tag(3)
                Text("AccessoryInline").tag(4)
                Text("AccessoryCircular").tag(5)
                Text("AccessoryRectangular").tag(6)
                Text("All Sizes").tag(7)
            }
            .onChange(of: widgetSizeType) { value in
                print("preview size changed : \(value)")
                if value != 7 {
                    self.state.changeWidgetSizeType(value)
                }
            }
            Toggle(isOn: $isDebugMode) {
                Label("Debug Borders", systemImage: "square.dashed")
            }

            Picker("Rendering Environment", selection: $widgetRenderingMode) {
                Text("Full Color").tag("fullColor")
                Text("Accented").tag("accented")
                Text("Vibrant").tag("vibrant")
            }
            .pickerStyle(.segmented)
            .onChange(of: widgetRenderingMode) { value in
                state.changeWidgetRenderingMode(value)
            }
            
            HStack {
                TextField("Parameter", text: $scriptParameter)
                    .focused($scriptParameterIsFocused)
                Button {
                    scriptParameterIsFocused = false
                    
                    self.scriptParameterApplied = self.scriptParameter
                    self.state.changeWidgetParameter(self.scriptParameterApplied)
                    
                } label: {
                    Text("Apply")
                }
            }
        }
    }

    private var previewSizeLabel: String {
        if widgetSizeType == 7 { return "Small · Medium · Large" }
        let size = WidgetSizeHelper.size(Int32(widgetSizeType))
        return "\(Int(size.width)) × \(Int(size.height))"
    }
    
    
    
}

private struct ScriptCodeAllSizesPreview: View {
    let model: ScriptModel
    let filePath: URL
    let scriptParameter: String
    let widgetRenderingMode: String
    let isDebugMode: Bool

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 20) {
                ForEach([0, 1, 2], id: \.self) { sizeType in
                    ScriptCodePreviewCard(
                        model: model,
                        filePath: filePath,
                        sizeType: sizeType,
                        scriptParameter: scriptParameter,
                        widgetRenderingMode: widgetRenderingMode,
                        isDebugMode: isDebugMode
                    )
                }
            }
            .padding(24)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .frame(minHeight: 430)
        .accessibilityLabel("All widget sizes preview")
    }
}

private struct ScriptCodePreviewCard: View {
    @StateObject private var state: ScriptCodePreviewDataObject
    let sizeType: Int
    let scriptParameter: String
    let widgetRenderingMode: String
    let isDebugMode: Bool

    init(model: ScriptModel, filePath: URL, sizeType: Int, scriptParameter: String, widgetRenderingMode: String, isDebugMode: Bool) {
        self.sizeType = sizeType
        self.scriptParameter = scriptParameter
        self.widgetRenderingMode = widgetRenderingMode
        self.isDebugMode = isDebugMode
        _state = StateObject(wrappedValue: ScriptCodePreviewDataObject(
            model: model,
            filePath: filePath,
            widgetSizeType: sizeType,
            scriptParameter: scriptParameter,
            widgetRenderingMode: widgetRenderingMode
        ))
    }

    var body: some View {
        let size = WidgetSizeHelper.size(Int32(sizeType))
        VStack(spacing: 8) {
            Text(["Small", "Medium", "Large"][sizeType])
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScriptWidgetElementView(
                element: state.rootElement,
                context: ScriptWidgetElementContext(
                    runtime: state.runtime,
                    debugMode: isDebugMode,
                    scriptName: state.model.package.name,
                    scriptParameter: scriptParameter,
                    package: state.model.package
                )
            )
            .frame(width: size.width, height: size.height)
            .background(Color(.systemBackground))
            .clipShape(.rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        }
        .onChange(of: scriptParameter) { value in
            state.changeWidgetParameter(value)
        }
        .onChange(of: widgetRenderingMode) { value in
            state.changeWidgetRenderingMode(value)
        }
    }
}

struct ScriptCodePreviewView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ScriptCodePreviewView(model: globalScriptModel, filePath: .constant(URL(string:"/Users/main.jsx")!))
                .preferredColorScheme(.light)
            ScriptCodePreviewView(model: globalScriptModel, filePath: .constant(URL(string:"/Users/main.jsx")!))
                .preferredColorScheme(.dark)
        }
    }
}
