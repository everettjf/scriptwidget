//
//  AppUtility.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/13.
//

import SwiftUI
import UIKit
import StoreKit

extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

class AppHelper {
    static func getAlternateIconNames() -> [String] {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any] else { return [] }
        guard let alternateIcons = icons["CFBundleAlternateIcons"] as? [String: Any] else { return [] }
        
        var iconNames = [String]()
        for (_, value) in alternateIcons {
            guard let iconList = value as? Dictionary<String,Any> else { break }
            guard let iconFiles = iconList["CFBundleIconFiles"] as? [String] else{ break }
            guard let icon = iconFiles.first else { break }
            
            iconNames.append(icon)
        }
        
        return iconNames
    }
    
    static func getCurrentIconName() -> String {
        if let name = UIApplication.shared.alternateIconName {
            return name
        }
        return "color4"
    }
    
    static func getAppVersion() -> String {
        let mainVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return "\(mainVersion ?? "1.0").\(buildVersion ?? "0")"
    }
    
    @MainActor static func requestReview() {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { scene in
                scene.activationState == .foregroundActive
                    && scene.windows.contains(where: \.isKeyWindow)
            }

        guard let windowScene else { return }
        AppStore.requestReview(in: windowScene)
    }
    
    static func isdarkmode() -> Bool {
        return UITraitCollection.current.userInterfaceStyle == .dark
    }
    
}
