//
//  DeleteConfirmView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/25.
//

import SwiftUI

struct DeleteConfirmView: View {
    @Environment(\.dismiss) var dismiss
    @State private var deleteReceipt: ScriptWidgetStoragePublicationReceipt?
    
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
                    
                    let result = deleteReceipt.map { sharedScriptManager.deleteScript(packageName: inputText, expectedReceipt: $0) } ?? false
                    if !result {
                        MacKitUtil.alertWarn(title: "Delete Failed", message: ScriptManager.deleteFailureMessage)
                        return
                    }
                    
                    NotificationCenter.default.post(name: SharedAppStore.scriptCreateNotification, object: nil)
                    
                    dismiss()
                }
            }
        }
        .frame(width: 300, height: 70)
        .padding()
        .onAppear { deleteReceipt = sharedScriptManager.deletionReceipt(packageName: currentName.wrappedValue) }
    }
}

//struct DeleteConfirmView_Previews: PreviewProvider {
//    static var previews: some View {
//        DeleteConfirmView()
//    }
//}
