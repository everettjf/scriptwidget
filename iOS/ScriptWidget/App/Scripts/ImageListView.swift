//
//  LocalImageListView.swift
//  ScriptWidget
//
//  Created by everettjf on 2022/2/1.
//

import SwiftUI
import SDWebImageSwiftUI


class ImageDataObject: ObservableObject {
    @Published var images = [ImageModel]()
    
    let model: ScriptModel
    
    // local images
    init(model: ScriptModel) {
        self.model = model
        reload()
        addObserver()
    }
    
    func addObserver() {
        
        NotificationCenter.default.addObserver(forName: PhotoPickerViewController.newSaveNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reload()
        }
        
        NotificationCenter.default.addObserver(forName: ImagePreviewView.imageDeleteNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reload()
        }
        
        NotificationCenter.default.addObserver(forName: ImagePreviewView.imageRenameNotification, object: nil, queue: OperationQueue.main) { (noti) in
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
    @State private var previewingImage: ImageModel?
    @State private var isAddingImage: Bool = false
    @StateObject private var dataObject: ImageDataObject
    
    let title: String
    
    init(model: ScriptModel) {
        _dataObject = StateObject(wrappedValue: ImageDataObject(model: model))
        self.title = "Images"
    }
    
    var body: some View {
        GeometryReader { proxy in
            // Use this view's available width so thumbnails follow scene resizing.
            let size = min(max((proxy.size.width - 32) / 3 - 10, 1), 110)
            let columns = [GridItem(.adaptive(minimum: size), spacing: 5)]
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    if dataObject.images.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.largeTitle)
                            Text("No images yet")
                                .font(.headline)
                            Text("Add an image to use it from your widget script.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                    ForEach(dataObject.images) { item in
                        Button(action: {
                            self.previewingImage = item
                        }) {
                        
                            VStack(alignment: .leading, spacing: 8) {
                                GeometryReader { thumbnail in
                                    WebImage(url: item.path)
                                        .placeholder {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(.quaternary)
                                        }
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: thumbnail.size.width, height: size)
                                        .clipped()
                                }
                                .frame(height: size)
                                .clipShape(.rect(cornerRadius: 12))
                                Text(item.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingImage = true
                } label: {
                    Label("Add Image", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $isAddingImage) {
            PhotoPickerView(scriptModel: dataObject.model)
        }
        .fullScreenCover(item: self.$previewingImage) { item in
            ImagePreviewView(model: dataObject.model, image: item)
        }
    }

}

struct LocalImageListView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ImageListView(model: globalScriptModel)
            ImageListView(model: globalScriptModel)
                .previewInterfaceOrientation(.landscapeRight)
        }
    }
}
