//
//  AppStore.swift
//  ScriptWidgetMac
//
//  Created by everettjf on 2022/1/15.
//

import Foundation


class SharedAppStore: ObservableObject {
    
    public static let scriptCreateNotification = Notification.Name("SharedAppStore_NewScript")

    
    @Published var scriptModels = [ScriptModel]()

    private let packages: any ScriptPackageListing
    
    init(packages: any ScriptPackageListing = DefaultScriptPackageRepository()) {
        self.packages = packages
        reloadUserScripts()
        addObserver()
    }
    
    func addObserver() {
        NotificationCenter.default.addObserver(forName: SharedAppStore.scriptCreateNotification, object: nil, queue: OperationQueue.main) { (noti) in
            self.reloadUserScripts()
        }
        NotificationCenter.default.addObserver(forName: GalleryInstaller.changedNotification, object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.reloadUserScripts()
        }
    }
    
    func reloadUserScripts() {
        DispatchQueue.global().async { [self] in
            let items = packages.listScripts()
            DispatchQueue.main.async {
                self.scriptModels = items
            }
        }
    }
    
}
