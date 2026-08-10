//
//  ImageAddView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/2/4.
//

import SwiftUI


class ImageAddDataObject: ObservableObject {
    @Published var imagePath: URL?
    @Published var image: NSImage?
    
    func loadImage(_ imagePath: URL) {
        self.imagePath = imagePath
        self.image = NSImage(contentsOf: imagePath)
    }
}


struct ImageAddView: View {
    @Environment(\.dismiss) var dismiss

    let scriptModel: ScriptModel
    
    @StateObject private var dataObject = ImageAddDataObject()
    @State private var croppedImage: NSImage?

    var body: some View {
        VStack {
            HStack {
                VStack {
                    Text("Original Image")
                        .padding()
                    
                    if let image = dataObject.image {
                        SWImageCropperView(inputImage: image, croppedImage: $croppedImage, cropRatios: [
                            SWImageCropRatio(width: 169, height: 169, title: "Small", image: "square.dashed"),
                            SWImageCropRatio(width: 360, height: 169, title: "Medium", image: "rectangle"),
                            SWImageCropRatio(width: 360, height: 376, title: "Large", image: "squareshape"),
                        ])
                    } else {
                        Button("Select") {
                            MacKitUtil.selectFile(title: "Select Image") { path in
                                guard let path = path else {
                                    return
                                }
                                print("path : \(path.path)")
                                dataObject.loadImage(path)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.gray)

                VStack {
                    Text("Cropped Image")
                        .padding()
                    if let croppedImage = croppedImage {
                        Image(nsImage: croppedImage)
                    } else {
                        Image(systemName: "photo")
                    }
                }
                .frame(width: 360 / 2 + 10)
                .frame(maxHeight: .infinity)
                .border(Color.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            HStack {
                Spacer()
                Button("Cancel") {
                    self.dismiss()
                }
                Button("Add Cropped Image") {
                    guard let croppedImage = croppedImage else {
                        return
                    }
                    
                    let imageName = "image\(scriptModel.package.getImageList().count)"
                    let result = scriptModel.package.saveImage(image: croppedImage, imageName: imageName)
                    if !result {
                        MacKitUtil.alertWarn(title: "Tip", message: "Failed save image, please retry.")
                        return
                    }
                    
                    NotificationCenter.default.post(name: ImageDataObject.refreshNotification, object: nil)
                    self.dismiss()
                }
                
                Button("Add Without Crop") {
                    guard let imagePath = dataObject.imagePath else {
                        return
                    }
                    
                    let result = scriptModel.package.saveImage(imagePath: imagePath)
                    if !result {
                        MacKitUtil.alertWarn(title: "Tip", message: "Failed save image, please retry.")
                        return
                    }
                    NotificationCenter.default.post(name: ImageDataObject.refreshNotification, object: nil)
                    self.dismiss()
                }
            }
        }
        .frame(width: 800, height: 600)
        .padding()
    }
}

struct ImageAddView_Previews: PreviewProvider {
    static var previews: some View {
        ImageAddView(scriptModel: globalScriptModel)
    }
}
