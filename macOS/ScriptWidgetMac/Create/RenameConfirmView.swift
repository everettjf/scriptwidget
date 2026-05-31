//
//  RenameConfirmView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/25.
//

import SwiftUI

struct RenameConfirmView: View {
    @Environment(\.dismiss) var dismiss
    
    var currentName: Binding<String>
    var inputName: Binding<String>
    
    var body: some View {
        VStack(alignment:.leading) {
            Text("Script name :")
                .font(.headline)
            
            TextField("", text: inputName)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Confirm") {
                    
                    let inputText = self.inputName.wrappedValue.trim()
                    if inputText.isEmpty {
                        MacKitUtil.alertWarn(title: "Invalid name", message: "Name can not be empty")
                        return
                    }
                    
                    if !inputText.checkIfValidFileName() {
                        MacKitUtil.alertWarn(title: "Invalid name", message: "Please make sure the widget name is an valid file name")
                        return;
                    }
                    
                    let newName = inputText
                    let oldName = self.currentName.wrappedValue
                    
                    print("old name = \(oldName)")
                    print("new name = \(newName)")
                    if oldName.compare(newName) == ComparisonResult.orderedSame {
                        print("equal name")
                        dismiss()
                        return
                    }
                    
                    let (result, error) = sharedScriptManager.renameScript(srcPackageName: oldName, destPackageName: newName)
                    if !result {
                        MacKitUtil.alertWarn(title: "Rename Failed", message: error.isEmpty ? "Could not rename the widget. A widget with that name may already exist." : error)
                        return
                    }
                    
                    NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
                    
                    dismiss()
                }
            }
        }
        .frame(width: 300, height: 100)
        .padding()
    }
}
//
//struct RenameConfirmView_Previews: PreviewProvider {
//    static var previews: some View {
//        RenameConfirmView(currentName: "Current Widget Name")
//    }
//}
