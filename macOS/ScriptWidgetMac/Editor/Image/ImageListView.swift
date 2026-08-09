//
//  ImageListView.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/2/4.
//

import SwiftUI
import UniformTypeIdentifiers


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
    @State private var showingAssetImporter = false
    @State private var previewingImage: ImageModel?
    @State private var isDropTargeted = false
    @State private var errorMessage: String?
    
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
                    Label("Crop Image", systemImage: "crop")
                }
                Button {
                    showingAssetImporter = true
                } label: {
                    Label("Import Assets", systemImage: "square.and.arrow.down")
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
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self, action: importDroppedAssets, isTargeted: { isDropTargeted = $0 })
        }
        .sheet(isPresented: $showingAddImage) {
            ImageAddView(scriptModel: scriptModel)
        }
        .fileImporter(
            isPresented: $showingAssetImporter,
            allowedContentTypes: [.image, .gif],
            allowsMultipleSelection: true,
            onCompletion: importSelectedAssets
        )
        .alert("Asset Import Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func importSelectedAssets(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
            return
        }
        _ = importAssets(urls)
    }

    private func importDroppedAssets(_ urls: [URL], _ location: CGPoint) -> Bool {
        importAssets(urls)
    }

    @discardableResult
    private func importAssets(_ urls: [URL]) -> Bool {
        let allowed = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
        var importedAny = false
        for url in urls where allowed.contains(url.pathExtension.lowercased()) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let result = scriptModel.package.importProjectFile(from: url)
            guard result.0 else {
                errorMessage = result.1
                return false
            }
            importedAny = true
        }
        if importedAny {
            dataObject.reload()
            NotificationCenter.default.post(name: ImageDataObject.refreshNotification, object: nil)
        } else {
            errorMessage = "Choose PNG, JPEG, GIF, WebP, or HEIC files."
        }
        return importedAny
    }
}

struct ImageListView_Previews: PreviewProvider {
    static var previews: some View {
        ImageListView(scriptModel: globalScriptModel)
    }
}
