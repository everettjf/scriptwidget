//
//  ScriptWidgetElementTagLink.swift
//  ScriptWidget
//
//  Created by everettjf on 2021/4/12.
//

import SwiftUI


struct ScriptWidgetElementTagLink {
    
    static func buildView(_ element: ScriptWidgetRuntimeElement, _ context: ScriptWidgetElementContext) -> AnyView {
        
        return AnyView(ScriptWidgetElementTagLink.buildVStack(
            element: element,
            context: context
        ))
    }
    
    @ViewBuilder static func buildVStack(element: ScriptWidgetRuntimeElement, context: ScriptWidgetElementContext) -> some View {
        Link( destination: ScriptWidgetElementTagLink.getDestination("url", element)) {
            ForEach(element.childrenAsElements()) { item -> AnyView in
                return ScriptWidgetElementView.buildView(element: item, context: context)
            }
        }
        .buttonStyle(.plain)
        .modifier(ScriptWidgetAttributeGeneralModifier(element, context))
    }
    
    static func getDestination(_ attrName: String, _ element: ScriptWidgetRuntimeElement) -> URL {
        
        guard let urlString = element.getPropString(attrName) else {
            return kDeepLinkDefaultURL
        }
        
        guard let url = URL(string: urlString) else {
            return kDeepLinkDefaultURL
        }
        
        return url
    }
    
}
struct ScriptWidgetElementTagLinkSample: View {
    var body: some View {
        VStack {
            Link(destination: URL(string: "widget-deeplink://standingsAAA")!) {
                Text("Link Test1")
                Text("Link Test2")
            }
            Link(destination: URL(string: "widget-deeplink://standingsBBB")!) {
                VStack {
                    Text("Link Test3")
                    Text("Link Test4")
                }
            }
            Link("Hello", destination: URL(string: "widget-deeplink://standingsBBB")!)
        }
    }
}

struct ScriptWidgetElementTagLinkSample_Previews: PreviewProvider {
    static var previews: some View {
        ScriptWidgetElementTagLinkSample()
    }
}
