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
    @ObservedObject var dataObject: ImageDataObject
    
    let size: CGFloat
    let columns: [GridItem]
    let title: String
    
    init(model: ScriptModel) {
        // Cap thumbnail size so the grid stays well-proportioned on iPad / wide
        // multitasking windows instead of rendering a few oversized images.
        self.size = min(screenShortLength / 3 - 10, 110)
        self.columns = [
            GridItem(.adaptive(size), spacing: 5),
        ]
        self.dataObject = ImageDataObject(model: model)
        self.title = "Images"
    }
    
    var body: some View {
        ScrollView(.vertical) {
            
            LazyVGrid(columns: columns) {
                ForEach(dataObject.images) { item in
                    Button(action: {
                        self.previewingImage = item
                    }) {
                        
                        VStack {
                            WebImage(url: item.path)
                                .placeholder {
                                    Rectangle().foregroundColor(.gray)
                                }
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: size)
                                .cornerRadius(5)
                            Text(item.name)
                        }
                    }
                }
            }
        }
        .padding(.top)
        .padding(.bottom)
        .navigationBarTitle(Text(LocalizedStringKey(self.title)), displayMode: .inline)
        .navigationBarItems(trailing: Button(action: {
            self.isAddingImage.toggle()
        }, label: {
            Image(systemName: "plus.square")
                .padding(.leading, 30)
                .padding(.top, 5)
                .padding(.bottom, 5)
        }).accessibilityLabel(Text("Add Image")))
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
