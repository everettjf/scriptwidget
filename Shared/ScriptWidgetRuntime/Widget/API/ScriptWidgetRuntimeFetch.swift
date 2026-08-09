//
//  ScriptWidgetRuntimeFetch.swift
//  ScriptWidget
//
//  Created by everettjf on 2020/12/11.
//

import Foundation
import JavaScriptCore


final class ScriptWidgetFetchManager: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumRequestBodyBytes = 1 * 1_024 * 1_024
    static let allowedSchemes = Set(["https", "http"])
    private struct Transfer {
        var data = Data()
        var response: URLResponse?
        let completion: (Data?, URLResponse?, Error?) -> Void
    }
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 10.0
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    func makeTask(httpMethod: String, url: URL, params: [AnyHashable : Any]?, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        
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
            
            request.timeoutInterval = ScriptWidgetFetchPolicy.normalizedTimeout(params["timeoutInterval"] as? Double)
        }
        if let body = request.httpBody, body.count > Self.maximumRequestBodyBytes {
            request.httpBody = nil
        }
        return makeTask(request: request, completionHandler: completionHandler)
    }

    func makeTask(request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        transfers[task.taskIdentifier] = Transfer(completion: completionHandler)
        lock.unlock()
        return task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= 0 || response.expectedContentLength <= Self.maximumResponseBytes else {
            completionHandler(.cancel)
            finish(taskIdentifier: dataTask.taskIdentifier, error: resourceError("Response exceeds the \(Self.maximumResponseBytes)-byte limit"))
            return
        }
        lock.lock()
        transfers[dataTask.taskIdentifier]?.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var transfer = transfers[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        guard ScriptWidgetFetchPolicy.canAppend(currentBytes: transfer.data.count, incomingBytes: data.count) else {
            transfers.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            dataTask.cancel()
            transfer.completion(nil, transfer.response, resourceError("Response exceeds the \(Self.maximumResponseBytes)-byte limit"))
            return
        }
        transfer.data.append(data)
        transfers[dataTask.taskIdentifier] = transfer
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(taskIdentifier: task.taskIdentifier, error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ScriptWidgetFetchPolicy.validationError(for: url) == nil else {
            completionHandler(nil)
            finish(taskIdentifier: task.taskIdentifier, error: resourceError("Redirect target is not allowed"))
            return
        }
        completionHandler(request)
    }

    private func finish(taskIdentifier: Int, error: Error?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: taskIdentifier)
        lock.unlock()
        guard let transfer else { return }
        transfer.completion(error == nil ? transfer.data : nil, transfer.response, error)
    }

    private func resourceError(_ message: String) -> Error {
        NSError(domain: "ScriptWidgetFetch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum ScriptWidgetFetchPolicy {
    static func normalizedTimeout(_ value: Double?) -> TimeInterval {
        min(10, max(1, value ?? 5))
    }

    static func canAppend(currentBytes: Int, incomingBytes: Int, limit: Int = ScriptWidgetFetchManager.maximumResponseBytes) -> Bool {
        currentBytes >= 0 && incomingBytes >= 0 && currentBytes <= limit - min(incomingBytes, limit + 1)
    }

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

enum ScriptWidgetNetworkPolicy {
    static func isValidDomainDeclaration(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return value == normalized && !normalized.contains("://") && !normalized.contains("/") && !normalized.contains(":")
            && !normalized.hasPrefix(".") && !normalized.hasSuffix(".")
            && normalized.range(of: "^[a-z0-9*.-]+$", options: .regularExpression) != nil
            && (!normalized.contains("*") || normalized.hasPrefix("*."))
    }

    static func host(_ host: String, matchesAny declarations: [String]) -> Bool {
        let value = host.lowercased()
        return declarations.contains { declaration in
            let domain = declaration.lowercased()
            if domain.hasPrefix("*.") {
                let suffix = String(domain.dropFirst(2))
                return value != suffix && value.hasSuffix("." + suffix)
            }
            return value == domain
        }
    }

    static func packageAllows(_ url: URL, package: ScriptWidgetPackage) -> Bool {
        guard let manifest = package.readManifest() else {
            // Packages without widget.json are legacy-compatible. A present but
            // malformed Package 2.0 manifest must fail closed.
            return !FileManager.default.fileExists(atPath: package.manifestPath.path)
        }
        guard manifest.permissions.contains(.network), let host = url.host else { return false }
        return self.host(host, matchesAny: manifest.networkDomains)
    }
}


let sharedFetchManager = ScriptWidgetFetchManager()


let internal_fetch:@convention(block) (String, String, [AnyHashable : Any]?)-> ScriptWidgetRuntimePromise = { (httpMethod, url,params) in
    return ScriptWidgetRuntimePromise { (resolve, reject) in
        guard let executionSession = JSContext.current()?.scriptWidgetRunningState?.executionSession,
              executionSession.isActive else {
            reject.call(withArguments: ["Execution session is no longer active"])
            return
        }
        
        guard let urlValue = URL(string: url) else {
            reject.call(withArguments: ["\(url) is not url"])
            return
        }
        if let validationError = ScriptWidgetFetchPolicy.validationError(for: urlValue) {
            reject.call(withArguments: [validationError])
            return
        }
        guard let state = JSContext.current()?.scriptWidgetRunningState,
              ScriptWidgetNetworkPolicy.packageAllows(urlValue, package: state.package) else {
            reject.call(withArguments: ["Network host is not declared in widget.json"])
            return
        }
        
        var task: URLSessionDataTask!
        task = sharedFetchManager.makeTask(httpMethod: httpMethod, url: urlValue, params: params) { (data, response, error) in
            executionSession.complete(task)
            guard executionSession.isActive else { return }
            if let error = error {
                reject.call(withArguments: [error.localizedDescription])
            } else if let data = data {
                guard data.count <= ScriptWidgetFetchManager.maximumResponseBytes else {
                    reject.call(withArguments: ["Response exceeds the 2097152-byte limit"])
                    return
                }
                if let responseType = params?["responseType"] as? String, responseType == "base64" {
                    let base64 = data.base64EncodedString()
                    resolve.call(withArguments: [base64])
                } else if let string = String(data: data, encoding: String.Encoding.utf8) {
                    resolve.call(withArguments: [string])
                } else {
                    reject.call(withArguments: ["\(urlValue) is empty"])
                }
            } else {
                reject.call(withArguments: ["\(urlValue) is empty"])
            }
        }
        guard executionSession.register(task) else {
            task.cancel()
            reject.call(withArguments: ["Network request budget exceeded"])
            return
        }
        task.resume()
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
