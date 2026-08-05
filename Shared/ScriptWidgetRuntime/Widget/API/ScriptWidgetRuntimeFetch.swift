//
//  ScriptWidgetRuntimeFetch.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/12/11.
//

import Foundation
import JavaScriptCore


class ScriptWidgetFetchManager {
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let allowedSchemes = Set(["https", "http"])
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

enum ScriptWidgetFetchPolicy {
    static func validationError(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              ScriptWidgetFetchManager.allowedSchemes.contains(scheme) else {
            return "Only HTTP and HTTPS URLs are allowed"
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "URL host is required" }
        let blocked = host == "localhost" || host == "::1" || host.hasSuffix(".local") ||
            host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") ||
            (host.split(separator: ".").count == 4 && host.split(separator: ".").first == "172" &&
             (16...31).contains(Int(host.split(separator: ".")[1]) ?? -1))
        return blocked ? "Local and private network hosts are not allowed" : nil
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
        if let validationError = ScriptWidgetFetchPolicy.validationError(for: urlValue) {
            reject.call(withArguments: [validationError])
            return
        }
        
        sharedFetchManager.fetch(httpMethod: httpMethod ,url: urlValue, params: params){ (data, response, error) in
            if let error = error {
                print("$fetch error : \(error)")
                reject.call(withArguments: [error.localizedDescription])
            } else if let data = data {
                guard data.count <= ScriptWidgetFetchManager.maximumResponseBytes else {
                    reject.call(withArguments: ["Response exceeds the 2097152-byte limit"])
                    return
                }
                if let responseType = params?["responseType"] as? String, responseType == "base64" {
                    let base64 = data.base64EncodedString()
                    print("$fetch base64 length: \(base64.count)");
                    resolve.call(withArguments: [base64])
                } else if let string = String(data: data, encoding: String.Encoding.utf8) {
                    print("$fetch string: \(string)");
                    resolve.call(withArguments: [string])
                } else {
                    print("$fetch unable to decode response as utf8");
                    reject.call(withArguments: ["\(urlValue) is empty"])
                }
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
