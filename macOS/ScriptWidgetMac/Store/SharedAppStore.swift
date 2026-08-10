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
    private var observers: [NSObjectProtocol] = []
    private var reloadGeneration = 0
    
    init(packages: any ScriptPackageListing = DefaultScriptPackageRepository()) {
        self.packages = packages
        reloadUserScripts()
        addObserver()
    }
    
    private func addObserver() {
        observers = [Self.scriptCreateNotification, GalleryInstaller.changedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reloadUserScripts()
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    
    func reloadUserScripts() {
        reloadGeneration += 1
        let generation = reloadGeneration
        DispatchQueue.global().async { [self] in
            let items = packages.listScripts()
            DispatchQueue.main.async {
                guard generation == self.reloadGeneration else { return }
                self.scriptModels = items
            }
        }
    }
    
}
