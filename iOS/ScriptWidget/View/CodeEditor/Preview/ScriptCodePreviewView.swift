//
//  ScriptCodeRunnerView.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/30.
//

import SwiftUI
struct ScriptCodePreviewView: View {
    @Environment(\.presentationMode) var presentationMode
    @SceneStorage("preview-size-type") var widgetSizeType = 0
    
    @State var isDebugMode = false
    @State var showAlert = false
    @State var showAlertMessage = ""
    
    @State var scriptParameter = ""
    @State var scriptParameterApplied = ""
    @FocusState private var scriptParameterIsFocused: Bool
    
    @ObservedObject var consoleData = ScriptCodePreviewConsoleDataObject()
  
    @ObservedObject var state: ScriptCodePreviewDataObject
    
    @Binding var filePath: URL
    
    init(model: ScriptModel, filePath: Binding<URL>) {
//        print("PreviewView init model-id: \(model.id)  file-path: \(filePath.wrappedValue)")
        
        self._filePath = filePath
        self.state = ScriptCodePreviewDataObject(model: model, filePath: filePath.wrappedValue, widgetSizeType: 0, scriptParameter: "")
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
            
            ZStack {
                Rectangle()
                    .fill(Color.secondary)
                    .opacity(0.2)
                
                preview
            }
            .frame(height: WidgetSizeHelper.size(Int32(self.widgetSizeType)).height + 5)
            
            Form {
                Section("Config") {
                    config
                }
                Section("Log") {
                    ScriptCodePreviewConsoleView(data: consoleData)
                }
            }
            .formStyle(.grouped)
        }
    }
    
    var header: some View {
        HStack {
            Spacer()
            
            Text("Preview (\(state.previewStatus))")
                .font(.body)
                .fontWeight(.bold)
            
            Spacer()
            
            Button (action: {
                presentationMode.wrappedValue.dismiss()
            }, label: {
                Image(systemName: "xmark")
            })
        }
        .padding()
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
        .background(UITraitCollection.current.userInterfaceStyle == .dark ? Color.black : Color.white)
        .cornerRadius(widgetSizeType == 5 ? (WidgetSizeHelper.size(Int32(self.widgetSizeType)).height / 2) :  10)
    }
    
    
    
    var config: some View {
        Group {
            Picker(selection: $widgetSizeType, label:Text("Preview Size")) {
                Text("Small").tag(0)
                Text("Medium").tag(1)
                Text("Large").tag(2)
                Text("ExtraLarge").tag(3)
                Text("AccessoryInline").tag(4)
                Text("AccessoryCircular").tag(5)
                Text("AccessoryRectangular").tag(6)
            }
            .onChange(of: widgetSizeType) { _, value in
                print("preview size changed : \(value)")

                self.state.changeWidgetSizeType(value)
            }
            Toggle("Debug Border", isOn:$isDebugMode)
            
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
