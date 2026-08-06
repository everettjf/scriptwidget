//
//  ImageListView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/2/4.
//

import SwiftUI


class ImageDataObject: ObservableObject {
    
    public static let refreshNotification = Notification.Name("ImageDataObjectRefreshImageListNotification")
    
    @Published var images = [ImageModel]()
    
    let model: ScriptModel
    
    // local images
    init(model: ScriptModel) {
        self.model = model
        reload()
        addObserver()
    }
    
    func addObserver() {
        NotificationCenter.default.addObserver(forName: ImageDataObject.refreshNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reload()
        }
    }
    
    func reload() {
        DispatchQueue.global().async { [self] in
            let images = model.package.getImageList()
            DispatchQueue.main.async {
                self.images = images
            }
        }
    }
}


struct ImageListView: View {
    
    let scriptModel: ScriptModel
    @StateObject private var dataObject: ImageDataObject
    
    @State private var showingAddImage = false
    @State private var previewingImage: ImageModel?
    
    @State private var selectedImageName = ""
    
    let size: CGFloat
    let columns: [GridItem]
    
    init(scriptModel: ScriptModel) {
        self.scriptModel = scriptModel
        _dataObject = StateObject(wrappedValue: ImageDataObject(model: scriptModel))
        self.size = 100
        self.columns = [
            GridItem(.adaptive(minimum: self.size, maximum: self.size), spacing: 5),
        ]
    }

    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Assets")
                    .font(.headline)
                Spacer()
                Button {
                    showingAddImage = true
                } label: {
                    Label("Add Image", systemImage: "plus")
                }
            }
            .padding(12)
            .background(.bar)

            ScrollView {
                if dataObject.images.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                        Text("No images yet").font(.headline)
                        Text("Add an image to use it in this widget.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(dataObject.images) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncImage(url: item.path) { image in
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(height: size)
                                    .clipShape(.rect(cornerRadius: 10))
                            } placeholder: {
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: size)
                            }
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
                        .contextMenu {
                            Button {
                                self.selectedImageName = item.name
                                MacKitUtil.inputBox(title: "Rename \(self.selectedImageName) ?",message: "", placeholder: "New image name") { inputText in
                                    let result = scriptModel.package.renameImage(name: self.selectedImageName, newName: inputText)
                                    
                                    if result.0 {
                                        // post
                                        NotificationCenter.default.post(name: ImageDataObject.refreshNotification, object: nil)
                                    } else {
                                        DispatchQueue.main.async {
                                            MacKitUtil.alertWarn(title: "Warn", message: "Failed rename image : \(result.1)")
                                        }
                                    }
                                }
                            } label: {
                                Label("Rename", systemImage: "pencil.circle")
                            }
                            Button {
                                self.selectedImageName = item.name
                                
                                MacKitUtil.alertWarn(title: "Delete \(self.selectedImageName) ?", message: "") { isOK in
                                    if !isOK {
                                        return
                                    }
                                    
                                    let result = scriptModel.package.deleteImage(name: self.selectedImageName)
                                    
                                    if result.0 {
                                        // post
                                        NotificationCenter.default.post(name: ImageDataObject.refreshNotification, object: nil)
                                    } else {
                                        DispatchQueue.main.async {
                                            MacKitUtil.alertWarn(title: "Warn", message: "Failed delete image : \(result.1)")
                                        }
                                    }
                                }

                            } label: {
                                Label("Delete", systemImage: "minus.circle")
                            }
                        }
                    
                    }
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $showingAddImage) {
            ImageAddView(scriptModel: scriptModel)
        }
    }
}

struct ImageListView_Previews: PreviewProvider {
    static var previews: some View {
        ImageListView(scriptModel: globalScriptModel)
    }
}
