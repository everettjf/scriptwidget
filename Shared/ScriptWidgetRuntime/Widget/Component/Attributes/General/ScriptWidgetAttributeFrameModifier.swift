//
//  ScriptWidgetAttributeFrameModifier.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/2/21.
//

import Foundation
import SwiftUI

/*
 
 frame="max"
 frame="max,topLeading"
 frame="10,20"
 frame="10,20,topLeading"
 
 frame="max,20"
 frame="10,max"
 frame="max,20,topLeading"
 frame="10,max,topLeading"
 */
struct ScriptWidgetAttributeFrameModifier: ViewModifier {
    
    
    enum AttributeFrameMode {
        /*
         nothing, no effect
         */
        case none
        /*
         max,topLeading
         */
        case max_alignment
        
        /*
         10,20
         10,20,topLeading
         */
        case width_height_alignment
        
        /*
         frame="10,max"
         frame="10,max,topLeading"
         */
        case width_alignment
        
        /*
         frame="max,20"
         frame="max,20,topLeading"
         */
        case height_alignment
    }
    
    let frameMode: AttributeFrameMode
    let alignment: Alignment
    let width: CGFloat
    let height: CGFloat
    
    init(_ element: ScriptWidgetRuntimeElement) {
        var frameMode: AttributeFrameMode = .none
        var alignment: Alignment = .center
        var width: CGFloat = 0
        var height: CGFloat = 0
        
        let numericFrame = (element.getProps()["frame"] as? NSNumber).flatMap { value -> String? in
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return String(value.doubleValue)
        }
        if let frameValue = element.getPropString("frame") ?? numericFrame {
            let parts = frameValue.split(separator: ",")
            if parts.count == 1 {
//                frame="max"
                if frameValue == "max" {
                    frameMode = .max_alignment
                } else if let side = Double(frameValue), side.isFinite, side >= 0 {
                    width = CGFloat(side)
                    height = CGFloat(side)
                    frameMode = .width_height_alignment
                }
            } else if parts.count == 2 {
                let part1 = String(parts[0])
                let part2 = String(parts[1])
                
                if let widthValue = Double(part1), let heightValue = Double(part2) {
//                    frame="10,20"
                    width = CGFloat(widthValue)
                    height = CGFloat(heightValue)
                    frameMode = .width_height_alignment
                } else {
                    if part1 == "max" {
//                        frame="max,20"
                        if let heightValue = Double(part2) {
                            height = CGFloat(heightValue)
                            frameMode = .height_alignment
                        } else {
//                        frame="max,topLeading"
                            alignment = ScriptWidgetAttributeFrameModifier.getAligmentFromName(part2)
                            frameMode = .max_alignment
                        }
                    }
                    
                    if part2 == "max" {
//                        frame="10,max"
                        if let widthValue = Double(part1) {
                            width = CGFloat(widthValue)
                            frameMode = .width_alignment
                        }
                    }
                }
            } else if parts.count == 3 {
                let part1 = String(parts[0])
                let part2 = String(parts[1])
                let part3 = String(parts[2])
                
                if let widthValue = Double(part1), let heightValue = Double(part2) {
//                frame="10,20,topLeading"
                    width = CGFloat(widthValue)
                    height = CGFloat(heightValue)
                    alignment = ScriptWidgetAttributeFrameModifier.getAligmentFromName(part3)
                    frameMode = .width_height_alignment
                }
                
                if part1 == "max" {
//                    frame="max,20,topLeading"
                    if let heightValue = Double(part2) {
                        height = CGFloat(heightValue)
                        alignment = ScriptWidgetAttributeFrameModifier.getAligmentFromName(part3)
                        frameMode = .height_alignment
                    }
                }
                
                if part2 == "max" {
//                    frame="10,max,topLeading"
                    if let widthValue = Double(part1) {
                        width = CGFloat(widthValue)
                        frameMode = .width_alignment
                        alignment = ScriptWidgetAttributeFrameModifier.getAligmentFromName(part3)
                    }
                }
            }
        }
        self.frameMode = frameMode
        self.alignment = alignment
        self.width = width
        self.height = height
    }
    
    @ViewBuilder
    func body(content: Content) -> some View {
        if frameMode == .some(.max_alignment){
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: alignment)
        } else if frameMode == .some(.width_height_alignment) {
            content
                .frame(width: width, height: height, alignment: alignment)
        } else if frameMode == .some(.width_alignment) {
            content
                .frame(width: width, alignment: alignment)
        } else if frameMode == .some(.height_alignment) {
            content
                .frame(height: height, alignment: alignment)
        } else {
            content
        }
    }
    
    static func getAligmentFromName(_ name: String) -> Alignment {
        switch name {
        case "center": return .center
        case "leading": return .leading
        case "trailing": return .trailing
        case "top": return .top
        case "bottom": return .bottom
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }
}

struct ScriptWidgetAttributeFrameModifier_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Rectangle()
                .fill(.red)
                .frame(height: 50)
                .frame(maxWidth: .infinity)
            Rectangle()
                .fill(.green)
                .frame(width: 50,height: 50)
        }
        .frame(width: 200,height: 300)
        .border(.gray)
    }
}
