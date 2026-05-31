//
//  LocalImagePreviewView.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/2/2.
//

import SwiftUI
import SDWebImageSwiftUI
import SDWebImage


struct LocalImagePreviewImageView: View {
    let image: ImageModel
    
    var body: some View {
        WebImage(url: image.path)
            .placeholder {
                Rectangle().foregroundColor(.gray)
            }
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 600)
            .padding(.horizontal)
            .cornerRadius(5)
    }
}



struct ImagePreviewView: View {
    
    public static let imageDeleteNotification = Notification.Name("LocalImageDataObjectImageDeleteNotification")
    public static let imageRenameNotification = Notification.Name("LocalImageDataObjectImageRenameNotification")
    
    @Environment(\.presentationMode) var presentationMode

    let image: ImageModel
    let scriptModel: ScriptModel?
    
    @State private var isShowingDeleteAlert = false
    @State private var isShowingRenameAlert = false
    
    init(model: ScriptModel?, image: ImageModel) {
        self.scriptModel = model
        self.image = image
    }
    
    var body: some View {
        VStack(alignment:.center) {
            
            Spacer()
            
            LocalImagePreviewImageView(image: image)
                .padding()
            
            Text(image.name)
                .font(.subheadline)
                .fontWeight(.bold)
                .padding()

            Spacer()
            
            Button(action: {
                // alert rename
                self.isShowingRenameAlert.toggle()
            }) {
                Text("Rename")
                    .font(.subheadline)
                    .foregroundColor(.blue)
                    .padding()
            }
            Button(action: {
                // delete
                print("delete")
                self.isShowingDeleteAlert = true
            }) {
                Text("Delete")
                    .font(.subheadline)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            presentationMode.wrappedValue.dismiss()
        }
        
        .inputAlert(isPresented: $isShowingRenameAlert, TextAlert(title: "Rename \"\(self.image.name)\" ?", textDefaultValue: self.image.name, actionAccept: { (inputText) in
            guard let newName = inputText else { return }
            if newName.isEmpty { return }
        
            print("new name = \(newName)")
            
            var result = (false, "")
            if let scriptModel = scriptModel {
                result = scriptModel.package.renameImage(name: self.image.name, newName: newName)
            }
            if result.0 {
                SDImageCache.shared.clearMemory()
                SDImageCache.shared.clearDisk(onCompletion: nil)
                
                NotificationCenter.default.post(name: ImagePreviewView.imageRenameNotification, object: nil)

                // confirm
                self.presentationMode.wrappedValue.dismiss()
            } else {
                let error = result.1
                print("rename error : \(error)")
            }
        }, actionCancel: {}))
        .inputAlert(isPresented: $isShowingDeleteAlert, TextAlert(title: "Delete \"\(self.image.name)\" ?", showTextField: false, actionAccept: { (inputText) in
            
            // real delete
            var result = (false, "")
            if let scriptModel = scriptModel {
                result = scriptModel.package.deleteImage(name: image.name)
            }
            if result.0 {
                SDImageCache.shared.clearMemory()
                SDImageCache.shared.clearDisk(onCompletion: nil)

                NotificationCenter.default.post(name: ImagePreviewView.imageDeleteNotification, object: nil)

                // confirm
                self.presentationMode.wrappedValue.dismiss()
            } else {
                let error = result.1
                print("delete error : \(error)")
            }
        }, actionCancel: {}))
    }
}

//struct LocalImagePreviewView_Previews: PreviewProvider {
//    static var previews: some View {
//        LocalImagePreviewView()
//    }
//}
