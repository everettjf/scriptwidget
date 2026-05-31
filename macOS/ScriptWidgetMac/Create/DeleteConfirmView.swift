//
//  DeleteConfirmView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/25.
//

import SwiftUI

struct DeleteConfirmView: View {
    @Environment(\.dismiss) var dismiss
    
    var currentName: Binding<String>
    
    var body: some View {
        VStack(alignment:.leading) {
            Text("Script name :")
                .font(.headline)
            
            Text(currentName.wrappedValue)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Confirm Delete") {
                    
                    let inputText = self.currentName.wrappedValue
                    if inputText.isEmpty {
                        return
                    }
                    
                    let result = sharedScriptManager.deleteScript(packageName: inputText)
                    if !result {
                        MacKitUtil.alertWarn(title: "Delete Failed", message: "Could not delete the widget. Please try again.")
                        return
                    }
                    
                    NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
                    
                    dismiss()
                }
            }
        }
        .frame(width: 300, height: 70)
        .padding()
    }
}

//struct DeleteConfirmView_Previews: PreviewProvider {
//    static var previews: some View {
//        DeleteConfirmView()
//    }
//}
