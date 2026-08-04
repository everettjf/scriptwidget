//
//  AppIconsView.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/16.
//

import SwiftUI

struct AppIconsView: View {
    
    private var iconNames = AppHelper.getAlternateIconNames()
    
    private var gridItemLayout = [
        GridItem(.adaptive(minimum: 50), spacing: 5)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: gridItemLayout) {
                
                Button(action: {
                    // reset
                    UIApplication.shared.setAlternateIconName(nil) { (error) in
                        if let err = error {
                            print("failed set icon : \(err)")
                        } else {
                            print("succeed change icon")
                        }
                    }
                }) {
                    ZStack {
                        Rectangle()
                            .fill(Color.pink)
                            .frame(width: 50, height: 50)
                            .cornerRadius(10)
                        Text("Reset")
                            .foregroundColor(.white)
                    }
                }
                
                ForEach(iconNames, id: \.self) { item in
                    
                    Button(action: {
                        print("item = \(item)")
                        
                        UIApplication.shared.setAlternateIconName(item) { (error) in
                            if let err = error {
                                print("failed set icon : \(err)")
                            } else {
                                print("succeed change icon")
                            }
                        }
                    }) {
                        Image(uiImage: UIImage(named: item) ?? UIImage())
                            .resizable()
                            .frame(width: 50, height: 50)
                            .cornerRadius(10)
                        
                    }
                    .padding()
                }
                
            }
        }
        .navigationBarTitle(Text("App Icons"), displayMode: .inline)
    }
}

struct AppIconsView_Previews: PreviewProvider {
    static var previews: some View {
        AppIconsView()
    }
}
