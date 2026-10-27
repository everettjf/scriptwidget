import AppKit
import SwiftUI
import JavaScriptCore
import ZipArchive

@main
struct ValidationWorkerMain {
    @MainActor static func main() async {
        let response = FileHandle(fileDescriptor:dup(STDOUT_FILENO),closeOnDealloc:true)
        dup2(STDERR_FILENO,STDOUT_FILENO)
        func send(_ value:[String:Any]) {
            var output=value
            if let issues=output["diagnostics"] as? [[String:Any]] {
                output["diagnostics"]=Array(issues.prefix(128)).map { issue -> [String:Any] in
                    var bounded=issue
                    if let message=issue["message"] as? String {bounded["message"]=String(message.prefix(2048))}
                    return bounded
                }
            }
            output["runtimeAPIVersion"]=ScriptWidgetRuntimeContract.apiVersion
            output["compilerFingerprint"]=ScriptWidgetCompiler.fingerprint
            writeJSON(output,to:response)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        var phase="package"
        do {
            var input=Data()
            while let part=try FileHandle.standardInput.read(upToCount:65536), !part.isEmpty {
                input.append(part)
                guard input.count <= 92 * 1024 * 1024 else { throw CLIError(code:"protocol.limit",message:"Worker request too large.",exitCode:2) }
            }
            let request=try JSONDecoder().decode(ValidationRequest.self,from:input)
            if request.command == "probe", let path=request.probePath {
                let canRead=(try? Data(contentsOf:URL(fileURLWithPath:path))) != nil
                let canWrite=FileManager.default.createFile(atPath:path+".worker-write",contents:Data())
                send(["ok":true,"outsideRead":canRead,"outsideWrite":canWrite]); return
            }
            guard ["check","render","pack"].contains(request.command), [1,2].contains(request.scale), ["light","dark"].contains(request.appearance),request.parameter.utf8.count <= 16384 else {throw CLIError(code:"protocol.arguments",message:"Invalid validation request.",exitCode:2)}
            try validateFiles(request.files)
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("validation-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            for file in request.files {
                let target=directory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try file.data.write(to:target,options:.atomic)
            }
            let package=ScriptWidgetPackage(path:directory,readonly:true)
            var diagnostics:[[String:Any]]=[]
            var manifest:WidgetPackageManifest?
            if package.hasManifest {
                guard let decoded=package.readManifest() else { throw CLIError(code:"package.manifest",message:"Invalid widget.json; legacy fallback is forbidden.") }
                let report=WidgetPackageManifestValidator.validate(decoded,package:package)
                diagnostics=report.issues.map{["severity":$0.severity.rawValue,"code":$0.code,"message":$0.message,"file":"widget.json"]}
                guard report.isValid else { send(["ok":false,"phase":"package","diagnostics":diagnostics]); exit(1) }
                manifest=decoded
            } else {
                diagnostics.append(["severity":"warning","code":"legacy_package","message":"No widget.json; legacy main.jsx preview only."])
            }
            guard let source=package.readMainFile().0 else { throw CLIError(code:"package.entry",message:"Entry source missing or not valid UTF-8.") }
            guard let babel=ScriptManager.readBundleFile(bundle:"support",fileName:"core.js") else { throw CLIError(code:"tool.resources",message:"Bundled compiler missing.",exitCode:2) }
            phase="compile"
            for file in request.files where ["js","jsx"].contains(URL(fileURLWithPath:file.path).pathExtension.lowercased()) {
                guard let text=String(data:file.data,encoding:.utf8) else { throw CLIError(code:"compile.encoding",message:"Source is not UTF-8: \(file.path)") }
                if let error=ScriptWidgetRuntimeContract.validateSource(text) { throw CLIError(code:"compile.limit",message:error.displayMessage) }
                if case .failure(let error)=ScriptWidgetCompiler.compile(file.path == (manifest?.entry ?? "main.jsx") ? ScriptWidgetCompiler.wrappedSource(text):text,babelContent:babel) {
                    diagnostics.append(["severity":"error","code":"compile.syntax","file":file.path,"message":error.displayMessage])
                    send(["ok":false,"phase":"compile","diagnostics":diagnostics]); exit(1)
                }
            }
            if request.command == "check" { send(["ok":true,"phase":"compile","diagnostics":diagnostics,"runtimeAPIVersion":ScriptWidgetRuntimeContract.apiVersion,"compilerFingerprint":ScriptWidgetCompiler.fingerprint]); return }
            if request.command == "pack" {
                phase="export"
                guard manifest != nil else { throw CLIError(code:"package.manifest_required",message:"Packing requires a valid Package 2.0 widget.json.") }
                let archive=directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".swt")
                defer { try? FileManager.default.removeItem(at:archive) }
                guard SSZipArchive.createZipFile(atPath:archive.path,withContentsOfDirectory:directory.path,keepParentDirectory:false) else { throw CLIError(code:"export.failed",message:"Unable to create .swt.") }
                guard let error=ScriptPackageArchivePreflight.validate(archive) else {
                    let bytes=try Data(contentsOf:archive)
                    send(["ok":true,"phase":"export","diagnostics":diagnostics,"archive":bytes.base64EncodedString()]); return
                }
                throw CLIError(code:"export.invalid",message:error)
            }
            let families:[String:WidgetPackageFamily]=["small":.systemSmall,"medium":.systemMedium,"large":.systemLarge]
            guard let selected=families[request.family], manifest?.supportedFamilies.contains(selected) != false else { throw CLIError(code:"render.family",message:"Requested family is not supported by this package.") }
            phase="execute"
            let dark=request.appearance == "dark"
            let fixtures=try JSONSerialization.jsonObject(with:request.fixtures) as? [String:Any] ?? [:]
            let allowed=Set(["api","fetch","storage"])
            guard Set(fixtures.keys).isSubset(of:allowed) else { throw CLIError(code:"fixture.unsupported",message:"Native CLI currently supports api, fetch and storage fixture sections only.") }
            guard let catalogURL=Bundle.main.url(forResource:"api-catalog",withExtension:"json"), let hostURL=Bundle.main.url(forResource:"validation-host",withExtension:"js") else { throw CLIError(code:"tool.resources",message:"Validation host resources missing.",exitCode:2) }
            let catalog=try JSONSerialization.jsonObject(with:Data(contentsOf:catalogURL)) as! [[String:Any]]
            let ids=Set(catalog.compactMap{$0["id"] as? String})
            if let rules=fixtures["api"] as? [String:Any] {
                for (id,raw) in rules {
                    guard ids.contains(id), let rule=raw as? [String:Any], Set(rule.keys).isSubset(of:["value","error"]), (rule.keys.contains("value") != rule.keys.contains("error")), !rule.keys.contains("error") || rule["error"] is String else { throw CLIError(code:"fixture.invalid",message:"API fixture must have a known ID and exactly one value or error: \(id)") }
                }
            } else if fixtures["api"] != nil { throw CLIError(code:"fixture.invalid",message:"api must be an object.") }
            if let storage=fixtures["storage"] { guard let entries=storage as? [String:Any], entries.values.allSatisfy({$0 is String}) else { throw CLIError(code:"fixture.invalid",message:"storage must map keys to strings.") } }
            if let fetch=fixtures["fetch"] { guard let rules=fetch as? [[String:Any]], rules.allSatisfy({$0["url"] is String && ($0["body"] != nil || $0["error"] is String)}) else { throw CLIError(code:"fixture.invalid",message:"fetch must contain URL and body/error rules.") } }
            ScriptWidgetImagePipeline.validationRemoteImageLoader = { url in
                guard ScriptWidgetFetchPolicy.validationError(for:url) == nil, ScriptWidgetNetworkPolicy.packageAllows(url,package:package) else {
                    diagnostics.append(["severity":"warning","code":"image.permission","message":"Remote image URL is not permitted by the manifest; an offline placeholder was shown."])
                    return nil
                }
                if let rules=fixtures["fetch"] as? [[String:Any]], let body=rules.first(where:{$0["url"] as? String == url.absoluteString})?["body"] as? String,
                   body.hasPrefix("data:image/"), let comma=body.firstIndex(of:","), let bytes=Data(base64Encoded:String(body[body.index(after:comma)...])) {
                    return ScriptWidgetImagePipeline.image(data:bytes)
                }
                diagnostics.append(["severity":"warning","code":"image.fixture_missing","message":"Remote image has no data-image offline fixture; a placeholder was shown."])
                return nil
            }
            let runtime=ScriptWidgetRuntime(package:package,environments:["widget-size":request.family,"widget-param":request.parameter,"widget-rendering-mode":"fullColor"],isDarkMode:dark)
            let host=try String(contentsOf:hostURL,encoding:.utf8)
            runtime.validationHostInstaller={ [weak runtime] context in
                let permit:@convention(block)(String,String)->Bool={ capability,url in
                    if capability == "network" {
                        guard let target=URL(string:url), ScriptWidgetFetchPolicy.validationError(for:target) == nil else { return false }
                        return ScriptWidgetNetworkPolicy.packageAllows(target,package:package)
                    }
                    if capability == "runtime1.6" { return WidgetRuntimeRequirement.supports("1.6", current: manifest?.minimumRuntimeVersion ?? "0.0") }
                    return manifest == nil || manifest!.permissions.contains(where:{$0.rawValue == capability})
                }
                let note:@convention(block)(String,String)->Void={ code,message in if diagnostics.count < 128 {diagnostics.append(["severity":"warning","code":code,"message":String(message.prefix(2048))])} }
                let reserve:@convention(block)()->Bool={runtime?.runningState?.executionSession.registerDataQuery() ?? false}
                context["__validationReserve"]=unsafeBitCast(reserve,to:JSValue.self)
                context["__validationDiagnostic"]=unsafeBitCast(note,to:JSValue.self)
                context["__validationPermit"]=unsafeBitCast(permit,to:JSValue.self)
                let arguments=String(decoding:(try? jsonData([catalog,fixtures,dark])) ?? Data("[]".utf8),as:UTF8.self)
                context.evaluateScript("(\(host)).apply(null,\(arguments));")
                if let error=context.exception { diagnostics.append(["severity":"error","code":"fixture.host","message":error.toString() ?? "Invalid host fixtures"]) }
            }
            ScriptWidgetRenderClock.fixedNow=Date(timeIntervalSince1970:1767268800)
            let result=await Task.detached { runtime.executeJSXSyncForWidget(source) }.value
            guard let element=result.0 else { throw CLIError(code:"runtime.failed",message:result.1?.displayMessage ?? "No widget was rendered.") }
            if diagnostics.contains(where:{$0["severity"] as? String == "error"}) { send(["ok":false,"phase":"execute","diagnostics":diagnostics]); exit(1) }
            let sentinels=Set(["#UI Not Found#","#Failed#","#Loading#"])
            if element.getChildren().contains(where:{($0 as? String).map(sentinels.contains) ?? false}) {throw CLIError(code:"runtime.no_render",message:"No widget was rendered. Call $render with a native element.")}
            guard let componentURL=Bundle.main.url(forResource:"components",withExtension:"json"),let componentData=try JSONSerialization.jsonObject(with:Data(contentsOf:componentURL)) as? [String:Any], let tags=componentData["tags"] as? [String] else {throw CLIError(code:"tool.resources",message:"Native component contract missing.",exitCode:2)}
            let properties=componentData["properties"] as? [String:[String]] ?? [:]
            func inspect(_ item:ScriptWidgetRuntimeElement) throws {
                guard let tag=item.tagAsString(),tags.contains(tag) else {throw CLIError(code:"render.unknown_tag",message:"Unsupported native JSX tag. Use documented lowercase native tags.")}
                if tag == "image", item.getPropString("systemName") == nil, item.getPropString("url",or:"src") == nil, let name=item.getPropString("name",or:"id") {
                    if let image=package.getImage(name),ScriptWidgetImagePipeline.image(at:image.path) != nil {} else {diagnostics.append(["severity":"warning","code":"image.resource_missing","message":"A referenced package image is missing or could not be decoded; a placeholder will be shown."])}
                }
                if tag == "gif",let file=item.getPropString("file"),package.getGifFile(file) == nil {diagnostics.append(["severity":"warning","code":"gif.resource_missing","message":"A referenced GIF is missing from the package image directory."])}
                if let font=item.getPropString("font"),font.hasPrefix("custom,") {
                    let parts=font.split(separator:",")
                    if parts.count == 3,NSFont(name:String(parts[1]),size:12) == nil {diagnostics.append(["severity":"warning","code":"font.unavailable","message":"The requested custom font is not available to the standalone CLI; verify its appearance in the App."])}
                }
                if let allowed=properties[tag] {for key in item.getProps().keys.compactMap({$0 as? String}) where !allowed.contains(key) && diagnostics.count < 128 {diagnostics.append(["severity":"warning","code":"render.unknown_property","message":"Property \(key) on \(tag) is not in the versioned completion metadata; review its native support."])}}
                for child in item.childrenAsElements() {try inspect(child)}
            }
            try inspect(element)
            phase="render"
            let size=CGSize(width:request.family == "small" ? 169:360,height:request.family == "large" ? 376:169)
            let context=ScriptWidgetElementContext(runtime:runtime,debugMode:false,scriptName:package.name,scriptParameter:request.parameter,package:package,containerBackgroundElement:element)
            let view=ValidationWidgetView(element:element,context:context,size:size).environment(\.colorScheme,dark ? .dark:.light).environment(\.locale,Locale(identifier:"en_US")).environment(\.timeZone,TimeZone(secondsFromGMT:0)!)
            let renderer=ImageRenderer(content:view); renderer.scale=CGFloat(request.scale)
            var image:CGImage?
            (NSAppearance(named:dark ? .darkAqua:.aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance { image=renderer.cgImage }
            guard let image, let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]), png.count <= 10*1024*1024 else { throw CLIError(code:"render.image",message:"Native PNG unavailable or exceeds 10 MiB.",exitCode:2) }
            let logs=Array((runtime.runningState?.logger.logs ?? []).prefix(32)).map{String($0.prefix(1024))}
            send(["ok":true,"phase":"render","diagnostics":diagnostics,"png":png.base64EncodedString(),"width":image.width,"height":image.height,"logs":logs,"runtimeAPIVersion":ScriptWidgetRuntimeContract.apiVersion,"compilerFingerprint":ScriptWidgetCompiler.fingerprint])
        } catch {
            let failure=error as? CLIError ?? CLIError(code:"tool.worker",message:error.localizedDescription,exitCode:2)
            send(["ok":false,"phase":phase,"diagnostics":[["severity":"error","code":failure.code,"message":failure.message]],"exitCode":failure.exitCode])
            exit(failure.exitCode)
        }
    }
}

private struct ValidationWidgetView:View {
    let element:ScriptWidgetRuntimeElement
    let context:ScriptWidgetElementContext
    let size:CGSize
    var body:some View {
        let background=element.getPropString("background").map(ScriptWidgetAttributeColor.init) ?? ScriptWidgetAttributeColor()
        ZStack {
            if let color=background.color { color } else if let gradient=background.gradient { gradient } else { Rectangle().fill(.background) }
            ScriptWidgetElementView(element:element,context:context)
        }.frame(width:size.width,height:size.height)
    }
}
