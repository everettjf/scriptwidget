//
//  ScriptWidgetRuntimeFetch.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/12/11.
//

import Foundation
import JavaScriptCore


class ScriptWidgetFetchManager {
    let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 10.0
        session = URLSession(configuration: config)
    }
    
    func fetch(httpMethod: String, url: URL, params: [AnyHashable : Any]?, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) {
        
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        if let params = params {
            if let headers = params["headers"] as? [AnyHashable : Any] {
                for item in headers {
                    if let key = item.key as? String, let value = item.value as? String {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                }
            }
            
            if let body = params["body"] as? [AnyHashable : Any] {
                if let bodyData = try? JSONSerialization.data(withJSONObject: body,options: []) {
                    if let _ = request.allHTTPHeaderFields?["Content-Type"] {
                        // nothing
                    } else {
                        // default for body
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                    request.httpBody = bodyData
                }
            }
            
            if let body = params["body"] as? String {
                if let bodyData = body.data(using: .utf8) {
                    request.httpBody = bodyData
                }
            }
            
            if let timeoutInterval = params["timeoutInterval"] as? Double {
                request.timeoutInterval = timeoutInterval
            }
        }
        
        session.dataTask(with: request, completionHandler: completionHandler)
            .resume()
    }
}


let sharedFetchManager = ScriptWidgetFetchManager()


let internal_fetch:@convention(block) (String, String, [AnyHashable : Any]?)-> ScriptWidgetRuntimePromise = { (httpMethod, url,params) in
    print("fetch [\(httpMethod)] url: \(url), params: \(String(describing: params))")
    
    return ScriptWidgetRuntimePromise { (resolve, reject) in
        
        guard let urlValue = URL(string: url) else {
            reject.call(withArguments: ["\(url) is not url"])
            return
        }
        
        sharedFetchManager.fetch(httpMethod: httpMethod ,url: urlValue, params: params){ (data, response, error) in
            if let error = error {
                print("$fetch error : \(error)")
                reject.call(withArguments: [error.localizedDescription])
            } else if let data = data, let string = String(data: data, encoding: String.Encoding.utf8) {
                print("$fetch string: \(string)");
                resolve.call(withArguments: [string])
            } else {
                print("$fetch unknown error");
                reject.call(withArguments: ["\(urlValue) is empty"])
            }
        }
    }
}


let custom_fetch:@convention(block) (String, [AnyHashable : Any]?)-> ScriptWidgetRuntimePromise = { (url,params) in
    return internal_fetch("GET", url, params)
}

@objc protocol ScriptWidgetRuntimeHttpExports: JSExport {
    static func get(_ url: String, _ params: [AnyHashable : Any]?)-> ScriptWidgetRuntimePromise
    static func post(_ url: String, _ params: [AnyHashable : Any]?)-> ScriptWidgetRuntimePromise
    static func put(_ url: String, _ params: [AnyHashable : Any]?)-> ScriptWidgetRuntimePromise
    static func patch(_ url: String, _ params: [AnyHashable : Any]?)-> ScriptWidgetRuntimePromise
    static func delete(_ url: String, _ params: [AnyHashable : Any]?)-> ScriptWidgetRuntimePromise
}

@objc public class ScriptWidgetRuntimeHttp: NSObject, ScriptWidgetRuntimeHttpExports {
    static func get(_ url: String, _ params: [AnyHashable : Any]?) -> ScriptWidgetRuntimePromise {
        return internal_fetch("GET", url, params)
    }
    
    static func post(_ url: String, _ params: [AnyHashable : Any]?) -> ScriptWidgetRuntimePromise {
        return internal_fetch("POST", url, params)
    }
    
    static func put(_ url: String, _ params: [AnyHashable : Any]?) -> ScriptWidgetRuntimePromise {
        return internal_fetch("PUT", url, params)
    }
    
    static func patch(_ url: String, _ params: [AnyHashable : Any]?) -> ScriptWidgetRuntimePromise {
        return internal_fetch("PATCH", url, params)
    }
    
    static func delete(_ url: String, _ params: [AnyHashable : Any]?) -> ScriptWidgetRuntimePromise {
        return internal_fetch("DELETE", url, params)
    }
}
