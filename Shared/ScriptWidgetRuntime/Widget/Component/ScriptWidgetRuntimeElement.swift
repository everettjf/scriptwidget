//
//  SwiftWidgetRuntimeElement.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/10/15.
//

import Foundation
import JavaScriptCore

@objc protocol ScriptWidgetRuntimeElementExports: JSExport {
    var tag: JSValue { get set }
    var props: [AnyHashable:Any]? { get set }
    var children: [Any]? { get set }
    
    static func createElement(_ tag: JSValue, _ props: [AnyHashable:Any]?, _ children: [Any]? ) -> ScriptWidgetRuntimeElement

}

@objc public class ScriptWidgetRuntimeElement: NSObject, ScriptWidgetRuntimeElementExports, Identifiable {
    dynamic var tag: JSValue
    dynamic var props: [AnyHashable:Any]? {
        didSet { parsedProps.removeAll(keepingCapacity: true) }
    }
    dynamic var children: [Any]?
    var depth = 0
    
    public let id = UUID()
    var tagString: String?
    private var parsedProps: [String: Any] = [:]

    required init(tag: JSValue, props: [AnyHashable:Any]?, children: [Any]?) {
        self.tag = tag
        self.props = props
        self.children = children
        self.tagString = nil
    }
    
    init(tagString: String, props: [AnyHashable:Any]?, children: [Any]?) {
        self.tag = JSValue()
        self.props = props
        self.children = children
        self.tagString = tagString
    }
    
    public func getProps() -> [AnyHashable:Any] {
        if let props = props {
            return props
        }
        return [:]
    }
    
    public func getChildren() -> [Any] {
        if let children = children {
            return children
        }
        return []
    }
    
    public func tagAsString() -> String? {
        if self.tag.isString {
            return self.tag.toString()
        }
        return self.tagString
    }
    
    public func childrenAsElements() -> [ScriptWidgetRuntimeElement] {
        var elements = [ScriptWidgetRuntimeElement]()
        guard let children = children else {
            return []
        }
        Self.convertAnyObjectsToElements(objects: children, elements: &elements)
        return elements
    }
    
    public static func convertAnyObjectsToElements(objects: [Any], elements: inout [ScriptWidgetRuntimeElement]) -> Void {
        for child in objects {
            
            // element directly
            if let child = child as? ScriptWidgetRuntimeElement {
                elements.append(child)
                continue
            }
            
            // array
            if let embedElements = child as? [Any] {
                Self.convertAnyObjectsToElements(objects: embedElements, elements: &elements)
                continue
            }
            
            // !!! should not go here, otherwise add more support code here is required
//            assert(false, "New element type found, type is \(type(of: child))")
        }
    }
    
    public func getPropString(_ key: String) -> String? {
        guard let props = self.props else { return nil }
        guard let value = props[key] as? String else { return nil }
        return value
    }
    
    public func getPropString(_ key: String, or: String) -> String? {
        if let value = self.getPropString(key) {
            return value
        }
        return self.getPropString(or);
    }
    
    public func getPropBool(_ key: String) -> Bool? {
        if let cached = parsedProps["bool:\(key)"] as? Bool { return cached }
        guard let props = self.props else { return nil }
        if let value = props[key] as? Bool {
            parsedProps["bool:\(key)"] = value
            return value
        }
        
        if let value = props[key] as? String {
            if value == "true" || value == "yes" {
                parsedProps["bool:\(key)"] = true
                return true
            }
            if value == "false" || value == "no" {
                parsedProps["bool:\(key)"] = false
                return false
            }
        }
        return nil
    }
    public func getPropInt(_ key: String) -> Int? {
        if let cached = parsedProps["int:\(key)"] as? Int { return cached }
        guard let props = self.props else { return nil }
        if let value = props[key] as? Int {
            parsedProps["int:\(key)"] = value
            return value
        }
        
        if let value = props[key] as? String {
            if let intValue = Int(value) {
                parsedProps["int:\(key)"] = intValue
                return intValue
            }
        }
        return nil
    }
    
    public func getPropDouble(_ key: String) -> Double? {
        if let cached = parsedProps["double:\(key)"] as? Double { return cached }
        guard let props = self.props else { return nil }
        if let value = props[key] as? Double {
            parsedProps["double:\(key)"] = value
            return value
        }
        if let value = props[key] as? String {
            if let doubleValue = Double(value) {
                parsedProps["double:\(key)"] = doubleValue
                return doubleValue
            }
        }
        return nil
    }
    
    class func createElement(_ tag: JSValue, _ props: [AnyHashable:Any]?, _ children: [Any]? ) -> ScriptWidgetRuntimeElement {
        return ScriptWidgetRuntimeElement(tag: tag, props: props, children: children)
    }
    
    public override var description: String {
        var indent = ""
        for _ in 0..<depth {
            indent += "    "
        }
        
        var desc = """
        \(indent)+ScriptWidgetRuntimeElement
        \(indent)  |tag: \(tag)
        \(indent)  |props: \(String(describing: props))
        """
        desc += "\n"
        
        if let children = self.children {
            if children.count == 0 {
                desc += "\(indent)  |children: None\n"
            } else {
                desc += "\(indent)  |children:\n"
                
                let childDepth = depth + 1
                for child in children {
                    var childIndent = ""
                    for _ in 0..<childDepth {
                        childIndent += "    "
                    }
                    
                    switch child {
                    case let child as ScriptWidgetRuntimeElement:
                        child.depth = childDepth
                        desc += "\(child)\n"
                    case let child as String:
                        desc += "\(childIndent)  String: \(child)\n"
                    case let child as NSNumber:
                        desc += "\(childIndent)  Number: \(child)\n"
                    default:
                        desc += "\(childIndent)  Unknown: \(type(of: child)) = \(child)\n"
                    }
                }
            }
        } else {
            desc += "\(indent)  |children: None\n"
        }
        
        return desc;
    }
}
