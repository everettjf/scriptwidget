//
//  EditAttributesView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/11.
//

import SwiftUI
import SwiftyJSON

struct EditAttributesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingDeleteAlert = false
    @State private var isShowingRenameFailedAlert = false
    @State private var inputName: String = ""
    
    let scriptModel: ScriptModel
    
    let actionDeleted: (() -> Void)?
    
    init(scriptModel: ScriptModel, actionDeleted: @escaping () -> Void) {
        self.scriptModel = scriptModel
        self.actionDeleted = actionDeleted
        
        _inputName = State(initialValue: scriptModel.name)
    }
    
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        NameAutoImageView(
                            name: scriptModel.name,
                            colors: getGradientColorsWithString(string: scriptModel.name),
                            size: 52
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(scriptModel.name)
                                .font(.headline)
                            Text("Widget project")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                Section {
                    TextField("Widget name", text: $inputName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("Name")
                } footer: {
                    Text("The name is also used for the project folder and widget picker.")
                }

                Section {
                    Button("Delete Widget", systemImage: "trash", role: .destructive) {
                        isShowingDeleteAlert = true
                    }
                } footer: {
                    Text("Deleting a widget removes its project files from ScriptWidget.")
                }
            }
            .navigationTitle("Widget Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        .alert("Delete \(scriptModel.name)?", isPresented: $isShowingDeleteAlert) {
            Button("Delete", role: .destructive, action: deleteWidget)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Couldn’t Rename Widget", isPresented: $isShowingRenameFailedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Choose a unique name that can also be used as a folder name.")
        }
    }

    private var trimmedName: String {
        inputName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedName.checkIfValidFileName()
    }

    private func save() {
        guard canSave else {
            isShowingRenameFailedAlert = true
            return
        }
        guard scriptModel.name != trimmedName else {
            dismiss()
            return
        }

        let result = sharedScriptManager.renameScript(
            srcPackageName: scriptModel.name,
            destPackageName: trimmedName
        )
        guard result.0 else {
            isShowingRenameFailedAlert = true
            return
        }

        NotificationCenter.default.post(
            name: ScriptWidgetHomeViewDataObject.scriptRenameNotification,
            object: nil,
            userInfo: ["newName": trimmedName]
        )
        dismiss()
    }

    private func deleteWidget() {
        guard sharedScriptManager.deleteScript(packageName: scriptModel.name) else { return }
        NotificationCenter.default.post(
            name: ScriptWidgetHomeViewDataObject.scriptDeleteNotification,
            object: nil
        )
        dismiss()
        actionDeleted?()
    }
}

#Preview("Widget Settings") {
    EditAttributesView(scriptModel: globalScriptModel, actionDeleted: {})
}
