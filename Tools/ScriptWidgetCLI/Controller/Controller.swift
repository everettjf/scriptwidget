import Foundation
import AppKit
import Darwin
import CoreGraphics
import Security

private let usage = """
ScriptWidget native validation CLI 0.2.0 (macOS 26+)
Usage:
  scriptwidget --version [--format json]
  scriptwidget doctor [--format json]
  scriptwidget check <package-dir> [--format json] [--fail-on-warning]
  scriptwidget render <package-dir> --output <directory> [--family small|medium|large]
    [--appearance light|dark|both] [--fixtures file.json] [--param text] [--scale 1|2]
    [--timeout 1..120] [--format json] [--fail-on-warning]
  scriptwidget preview <package-dir> [--no-open] [--format json] [--fail-on-warning]
  scriptwidget pack <package-dir> --output <file.swt> [--format json]
Native previews use isolated mock data. No app, account, Node or Chrome required.
"""

private struct Options {
    var command:String
    var input:String?
    var values:[String:String]=[:]
    var noOpen=false
    var strict=false
    var json=false
    init(_ arguments:[String]) throws {
        guard let first=arguments.first else { throw CLIError(code:"usage",message:usage,exitCode:2) }
        command=first
        var rest=Array(arguments.dropFirst())
        let allowed:Set<String>=["--format","--output","--family","--appearance","--fixtures","--param","--scale","--timeout"]
        while !rest.isEmpty {
            let token=rest.removeFirst()
            if token == "--no-open" { noOpen=true; continue }
            if token == "--fail-on-warning" { strict=true; continue }
            if token.hasPrefix("--") {
                guard allowed.contains(token), !rest.isEmpty, values[token] == nil else { throw CLIError(code:"usage",message:"Unknown, duplicate or incomplete option: \(token)",exitCode:2) }
                values[token]=rest.removeFirst()
            } else if input == nil { input=token } else { throw CLIError(code:"usage",message:"Only one package directory is accepted.",exitCode:2) }
        }
        if let format=values["--format"] { guard ["json","text"].contains(format) else { throw CLIError(code:"usage",message:"Format must be json or text.",exitCode:2) }; json=format == "json" }
        guard ["--version","doctor","check","render","pack","preview"].contains(command) else { throw CLIError(code:"usage",message:usage,exitCode:2) }
        let common:Set<String>=["--format","--timeout"]
        let permitted=command == "render" ? allowed : common.union(command == "pack" ? ["--output"]:[])
        guard !noOpen || command == "preview" else {throw CLIError(code:"usage",message:"--no-open requires preview.",exitCode:2)}
        guard Set(values.keys).isSubset(of:permitted), !strict || ["check","render","preview"].contains(command) else { throw CLIError(code:"usage",message:"Option not supported by this command.",exitCode:2) }
        guard (command == "--version" || command == "doctor") ? input == nil:input != nil else { throw CLIError(code:"usage",message:"Expected one package directory for this command.",exitCode:2) }
        guard (values["--param"] ?? "").utf8.count <= 16384, ["small","medium","large"].contains(values["--family"] ?? "medium"), ["light","dark","both"].contains(values["--appearance"] ?? "both"), ["1","2"].contains(values["--scale"] ?? "2"), let timeout=Double(values["--timeout"] ?? "60"), (1...120).contains(timeout) else { throw CLIError(code:"usage",message:"Invalid family, appearance, scale or timeout.",exitCode:2) }
    }
}
private final class Buffer:@unchecked Sendable {
    private let lock=NSLock()
    private var bytes=Data()
    private var exceeded=false
    func drain(_ handle:FileHandle,limit:Int) {
        while let chunk=try? handle.read(upToCount:65536), !chunk.isEmpty {
            lock.lock()
            if bytes.count+chunk.count <= limit { bytes.append(chunk) } else { exceeded=true }
            lock.unlock()
        }
    }
    var result:(Data,Bool) { lock.lock(); defer {lock.unlock()}; return (bytes,exceeded) }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock=NSLock()
    private var state=false
    var value:Bool {lock.lock();defer{lock.unlock()};return state}
    func set(){lock.lock();state=true;lock.unlock()}
}

@main
struct Controller {
    static func main() {
        signal(SIGPIPE,SIG_IGN)
        let arguments=Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains("--help") { print(usage); return }
        let json=arguments.contains("json")
        do {
            let options=try Options(arguments)
            let (report,code)=try run(options)
            if options.json { writeJSON(report) } else {
                print("ScriptWidget \(options.command): \(report["status"] ?? "unknown")")
                if let diagnostics=report["diagnostics"] as? [[String:Any]] { for issue in diagnostics { print("\(issue["severity"] ?? "error") [\(issue["code"] ?? "")] \(issue["message"] ?? "")") } }
                if let output=report["reportPath"] { print("Report: \(output)") }
                if let url=report["previewURL"] { print("Preview: \(url)") }
                if let skill=report["skillPath"] { print("Skill: \(skill)") }
            }
            exit(code)
        } catch {
            let issue=error as? CLIError ?? CLIError(code:"tool.io",message:error.localizedDescription,exitCode:2)
            let report:[String:Any]=["reportVersion":1,"command":arguments.first ?? "","status":issue.exitCode == 130 ? "cancelled":(issue.exitCode == 1 ? "failed":"error"),"tool":["version":cliVersion],"diagnostics":[["severity":"error","code":issue.code,"message":issue.message]]]
            if json { writeJSON(report) } else { FileHandle.standardError.write(Data((issue.message+"\n").utf8)) }
            exit(issue.exitCode)
        }
    }
    static var worker:URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ScriptWidgetValidationWorker.app/Contents/MacOS/ScriptWidgetValidationWorker") }
    private static func run(_ options:Options) throws -> ([String:Any],Int32) {
        var report:[String:Any]=["reportVersion":1,"command":options.command,"status":"passed","tool":["version":cliVersion,"buildCommit":Bundle.main.object(forInfoDictionaryKey:"ScriptWidgetBuildCommit") as? String ?? "development"],"backend":"static","diagnostics":[]]
        if options.command == "--version" { report["version"]=cliVersion; return (report,0) }
        guard FileManager.default.isExecutableFile(atPath:worker.path) else { throw CLIError(code:"tool.worker_missing",message:"Native worker missing. Reinstall scriptwidget-cli.",exitCode:2) }
        try validateWorkerSignature()
        let skillDirectory=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scriptwidget-creator")
        let referenceHash=sourceHash(try snapshot(skillDirectory))
        if options.command == "doctor" {
            report["system"]=ProcessInfo.processInfo.operatingSystemVersionString
            report["workerPath"]=worker.path
            report["skillPath"]=Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scriptwidget-creator").path
            report["nativeRenderRequirement"]="A logged-in macOS graphical session is required for SwiftUI screenshots."
            report["signature"]="valid"
            report["workerSandbox"]=true
            report["offline"]=true
            report["graphicalSessionAvailable"]=CGSessionCopyCurrentDictionary() != nil
            return (report,0)
        }
        if options.command == "render", CGSessionCopyCurrentDictionary() == nil { throw CLIError(code:"tool.graphical_session",message:"Native screenshots require a logged-in macOS graphical session.",exitCode:2) }
        let source=URL(fileURLWithPath:options.input!).standardizedFileURL
        let files=try snapshot(source)
        report["sourceHash"]=sourceHash(files)
        if options.command == "preview" {
            let request=ValidationRequest(command:"pack",files:files)
            let response=try execute(request,deadline:Date().addingTimeInterval(Double(options.values["--timeout"] ?? "60")!))
            let diagnostics=response["diagnostics"] as? [[String:Any]] ?? []
            report["diagnostics"]=diagnostics
            report["backend"]="web-handoff"
            let ok=response["ok"] as? Bool == true
            report["checks"]=["package":ok ? "passed":(response["phase"] as? String == "package" ? "failed":"passed"),"compile":ok ? "passed":(response["phase"] as? String == "compile" ? "failed":"notRun"),"execute":"notRun","render":"notRun","export":ok ? "passed":"notRun"]
            guard ok else { report["status"]="failed"; return (report,1) }
            if options.strict && diagnostics.contains(where:{$0["severity"] as? String == "warning"}) {report["status"]="failed"; return (report,1)}
            guard let encoded=response["archive"] as? String, let archive=Data(base64Encoded:encoded) else {throw CLIError(code:"tool.worker_protocol",message:"Worker did not return a valid preview package.",exitCode:3)}
            let payload=archive.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
            guard payload.count <= 60000 else {throw CLIError(code:"preview.link_limit",message:"Preview links support up to 45,000 compressed package bytes. Reduce large resources or export a .swt for manual import.",exitCode:1)}
            let url=URL(string:"https://atomsprout.com/scriptwidget/studio/#sw-preview=v1."+payload)!
            if options.noOpen { report["previewURL"]=url.absoluteString }
            report["browserLaunchRequested"]=false
            report["limitations"]=["Browser preview uses mock data and is not native validation.","The link contains your package; do not share it if the code or resources are private."]
            if !options.noOpen {
                guard NSWorkspace.shared.open(url) else {report["status"]="error"; report["diagnostics"]=diagnostics+[["severity":"error","code":"preview.browser","message":"Unable to open the default browser. Use preview --no-open to request a private link."]]; return (report,2)}
                report["browserLaunchRequested"]=true
            }
            return (report,0)
        }
        let fixtureData:Data
        if let filename=options.values["--fixtures"] {
            let url=URL(fileURLWithPath:filename)
            let info=try url.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey])
            guard info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 1024*1024 else { throw CLIError(code:"fixture.limit",message:"Fixture must be a regular JSON file up to 1 MiB.") }
            fixtureData=try Data(contentsOf:url)
            _=try JSONSerialization.jsonObject(with:fixtureData)
        } else { fixtureData=Data("{}".utf8) }
        let workerResources=worker.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let defaults=try Data(contentsOf:workerResources.appendingPathComponent("api-catalog.json"))
        var fixtureBytes=Data("ScriptWidgetFixtures/v1\n".utf8)
        for value in [defaults,fixtureData,Data("1".utf8)] { appendField(value,to:&fixtureBytes) }
        let fixturesDigest=sha256(fixtureBytes)
        report["fixturesHash"]=fixturesDigest
        report["sourceHashAlgorithm"]="ScriptWidgetSource/v1"
        let commit=Bundle.main.object(forInfoDictionaryKey:"ScriptWidgetBuildCommit") as? String ?? "development"
        let output=options.values["--output"].map{URL(fileURLWithPath:$0).standardizedFileURL}
        var runDirectory:URL?
        if ["render","pack"].contains(options.command) {
            guard let output else { throw CLIError(code:"usage",message:"--output is required.",exitCode:2) }
            let canonicalSource=source.resolvingSymlinksInPath().path
            let canonicalOutput=output.resolvingSymlinksInPath().path
            guard canonicalOutput != canonicalSource, !canonicalOutput.hasPrefix(canonicalSource+"/") else { throw CLIError(code:"output.inside_package",message:"Output must be outside the input package.",exitCode:2) }
            if options.command == "render" {
                let parent=try openDirectory(output,create:true)
                defer {close(parent)}
                let name="run-"+UUID().uuidString
                guard mkdirat(parent,name,0o700) == 0 else {throw CLIError(code:"output.mkdir",message:"Unable to create isolated output directory.",exitCode:2)}
                runDirectory=output.appendingPathComponent(name)
            } else {
                guard output.pathExtension == "swt" else { throw CLIError(code:"output.extension",message:"Pack output must end in .swt.",exitCode:2) }
                guard !FileManager.default.fileExists(atPath:output.path) else { throw CLIError(code:"output.exists",message:"Pack output exists; choose a new file.",exitCode:2) }
                try createSafeDirectory(output.deletingLastPathComponent())
            }
        }
        let appearances=options.command == "render" ? ((options.values["--appearance"] ?? "both") == "both" ? ["light","dark"]:[options.values["--appearance"]!]):["light"]
        let deadline=Date().addingTimeInterval(Double(options.values["--timeout"] ?? "60")!)
        var diagnostics:[[String:Any]]=[], artifacts:[[String:Any]]=[], checks:[String:Any]=["package":"notRun","compile":"notRun","execute":"notRun","render":"notRun","export":"notRun"]
        var code:Int32=0
        var variants:[[String:Any]]=[]
        for appearance in appearances {
            let request=ValidationRequest(command:options.command,files:files,family:options.values["--family"] ?? "medium",appearance:appearance,parameter:options.values["--param"] ?? "",fixtures:fixtureData,scale:Int(options.values["--scale"] ?? "2")!)
            let response=try execute(request,deadline:deadline)
            let ok=response["ok"] as? Bool == true
            diagnostics += response["diagnostics"] as? [[String:Any]] ?? []
            if let runtime=response["runtimeAPIVersion"] { report["runtimeAPIVersion"]=runtime }
            report["tool"]=["version":cliVersion,"buildCommit":commit,"runtimeAPIVersion":response["runtimeAPIVersion"] ?? "unknown","compilerFingerprint":response["compilerFingerprint"] ?? "unknown","referenceHash":referenceHash]
            if let fingerprint=response["compilerFingerprint"] { report["compilerFingerprint"]=fingerprint }
            let phase=response["phase"] as? String ?? "error"
            let stages=["package","compile","execute","render","export"]
            let completed=stages.firstIndex(of:phase) ?? 0
            for (index,stage) in stages.enumerated() {
                if index < completed { checks[stage]="passed" }
                if index == completed { checks[stage]=ok ? "passed":"failed" }
            }
            if options.command == "pack" { checks["execute"]="notRun"; checks["render"]="notRun" }
            if !ok { code=(response["exitCode"] as? NSNumber)?.int32Value ?? 1; report["status"]=code == 1 ? "failed":"error" }
            var requestBytes=Data("ScriptWidgetRequest/v1\n".utf8)
            #if arch(arm64)
            let architecture="arm64"
            #else
            let architecture="x86_64"
            #endif
            let fields=[options.command,sourceHash(files),fixturesDigest,cliVersion,commit,response["runtimeAPIVersion"] as? String ?? "",response["compilerFingerprint"] as? String ?? "","macOS",ProcessInfo.processInfo.operatingSystemVersionString,architecture,request.family,appearance,"fullColor",String(request.scale),request.parameter,"2026-01-01T12:00:00Z","UTC","en_US","42"]
            for field in fields {appendField(Data(field.utf8),to:&requestBytes)}
            let requestDigest=sha256(requestBytes)
            var variant:[String:Any]=["appearance":appearance,"status":ok ? "passed":"failed","phase":phase]
            variant["requestHash"]=requestDigest
            if let logs=response["logs"] { variant["logs"]=logs }
            if ok, let encoded=response["png"] as? String, let png=Data(base64Encoded:encoded), let directory=runDirectory {
                let filename=appearance+".png"
                try writeExclusive(png,to:directory.appendingPathComponent(filename))
                artifacts.append(["path":filename,"sha256":sha256(png),"bytes":png.count,"appearance":appearance,"sourceHash":sourceHash(files),"requestHash":requestDigest])
                variant["width"]=response["width"]; variant["height"]=response["height"]
            }
            if ok, options.command == "pack", let output, let encoded=response["archive"] as? String, let archive=Data(base64Encoded:encoded) {
                try writeExclusive(archive,to:output)
                artifacts.append(["path":output.path,"sha256":sha256(archive),"bytes":archive.count])
            }
            variants.append(variant)
            if !ok { break }
        }
        if options.strict && diagnostics.contains(where:{$0["severity"] as? String == "warning"}) { code=1; report["status"]="failed" }
        report["backend"]=options.command == "render" ? "mac-native":"static"
        report["checks"]=checks; report["diagnostics"]=diagnostics; report["artifacts"]=artifacts; report["variants"]=variants
        report["target"]=["platform":"macOS","family":options.values["--family"] ?? "medium","scale":Int(options.values["--scale"] ?? "2")!,"appearance":options.values["--appearance"] ?? "both"]
        report["limitations"]=["System APIs and networking use offline mock data.","SwiftUI snapshot only; WidgetKit installation, real permissions and interaction are not tested."]
        if let directory=runDirectory {
            report["reportPath"]=directory.appendingPathComponent("report.json").path
            try writeExclusive(try jsonData(report),to:directory.appendingPathComponent("report.json"))
        }
        return (report,code)
    }
    static func snapshot(_ directory:URL) throws -> [SnapshotFile] {
        let fd=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw CLIError(code:"input.directory",message:"Input must be an existing regular directory, not a symbolic link.",exitCode:2) }
        defer {close(fd)}
        var files:[SnapshotFile]=[]; var total=0; var entries=0
        func walk(_ parent:Int32,_ prefix:String,_ depth:Int) throws {
            guard depth <= 16, let stream=fdopendir(dup(parent)) else { throw CLIError(code:"package.path",message:"Package directory depth exceeds its limit.") }
            defer {closedir(stream)}
            while let entry=readdir(stream) {
                var tuple=entry.pointee.d_name
                let name=withUnsafePointer(to:&tuple){$0.withMemoryRebound(to:CChar.self,capacity:1024){String(cString:$0)}}
                if [".","..",".git","__Build",".scriptwidget-artifacts"].contains(name) {continue}
                entries += 1
                guard entries <= 500 else {throw CLIError(code:"package.limit",message:"Package exceeds 500 entries.")}
                let path=prefix.isEmpty ? name:prefix+"/"+name
                let child=openat(parent,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
                guard child >= 0 else { throw CLIError(code:"package.path",message:"Cannot safely open \(path).") }
                defer {close(child)}
                var before=stat(); guard fstat(child,&before) == 0 else {throw CLIError(code:"package.path",message:"Unable to inspect package file.")}
                if before.st_mode&S_IFMT == S_IFDIR {try walk(child,path,depth+1); continue}
                guard before.st_mode&S_IFMT == S_IFREG, before.st_nlink == 1, before.st_size >= 0, before.st_size <= 25*1024*1024, files.count < 500 else {throw CLIError(code:"package.path",message:"Unsafe, linked or oversized file: \(path)")}
                var data=Data(), buffer=[UInt8](repeating:0,count:65536)
                while true { let count=read(child,&buffer,buffer.count); guard count >= 0 else {throw CLIError(code:"package.read",message:"Unable to read \(path)")}; if count == 0 {break}; total += count; data.append(contentsOf:buffer.prefix(count)); guard total <= maximumSnapshotBytes, data.count <= 25*1024*1024 else {throw CLIError(code:"package.limit",message:"Package exceeded its byte budget.")} }
                var after=stat(); guard fstat(child,&after) == 0, before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {throw CLIError(code:"package.changed",message:"Package changed while reading; retry.")}
                files.append(SnapshotFile(path:path,data:data))
            }
        }
        try walk(fd,"",0); try validateFiles(files); return files
    }
    static func validateWorkerSignature() throws {
        let bundle=worker.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code:SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL,[],&code) == errSecSuccess,let code,
              SecStaticCodeCheckValidity(code,[],nil) == errSecSuccess else {throw CLIError(code:"tool.signature",message:"Native worker signature is invalid. Reinstall the CLI.",exitCode:2)}
        var raw:CFDictionary?
        guard SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&raw) == errSecSuccess,
              let info=raw as? [String:Any],let entitlements=info[kSecCodeInfoEntitlementsDict as String] as? [String:Any],entitlements["com.apple.security.app-sandbox"] as? Bool == true,
              entitlements["com.apple.security.network.client"] as? Bool != true,
              entitlements["com.apple.security.network.server"] as? Bool != true,
              entitlements["com.apple.security.application-groups"] == nil,
              entitlements["com.apple.developer.icloud-container-identifiers"] == nil,
              entitlements["keychain-access-groups"] == nil else {throw CLIError(code:"tool.worker_permissions",message:"Native validation worker has unexpected privileges.",exitCode:2)}
    }
    static func execute(_ request:ValidationRequest,deadline:Date) throws -> [String:Any] {
        let task=Process(), input=Pipe(), output=Pipe(), errors=Pipe()
        task.executableURL=worker; task.standardInput=input; task.standardOutput=output; task.standardError=errors
        task.environment=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TZ":"UTC"]
        let response=Buffer(), logs=Buffer(), group=DispatchGroup()
        try task.run()
        for (buffer,handle,limit) in [(response,output.fileHandleForReading,24*1024*1024),(logs,errors.fileHandleForReading,256*1024)] {
            group.enter(); DispatchQueue.global().async {buffer.drain(handle,limit:limit); group.leave()}
        }
        let data=try JSONEncoder().encode(request)
        group.enter(); DispatchQueue.global().async {try? input.fileHandleForWriting.write(contentsOf:data); try? input.fileHandleForWriting.close(); group.leave()}
        let cancelled=CancellationFlag()
        signal(SIGINT,SIG_IGN)
        let cancellation=DispatchSource.makeSignalSource(signal:SIGINT,queue:.global())
        cancellation.setEventHandler {cancelled.set(); if task.isRunning {task.terminate()}}; cancellation.resume()
        defer {cancellation.cancel(); signal(SIGINT,SIG_DFL)}
        while task.isRunning {
            if Date() > deadline || cancelled.value { task.terminate(); usleep(100000); if task.isRunning {kill(task.processIdentifier,SIGKILL)}; task.waitUntilExit(); group.wait(); throw CLIError(code:cancelled.value ? "cancelled":"tool.timeout",message:cancelled.value ? "Cancelled.":"Command exceeded its deadline.",exitCode:cancelled.value ? 130:124) }
            var memory=proc_taskinfo()
            let size=Int32(MemoryLayout.size(ofValue:memory))
            if proc_pidinfo(task.processIdentifier,PROC_PIDTASKINFO,0,&memory,size) == size, memory.pti_resident_size > 768*1024*1024 {
                task.terminate();usleep(100000);if task.isRunning {kill(task.processIdentifier,SIGKILL)}
                task.waitUntilExit();group.wait()
                throw CLIError(code:"runtime.memory",message:"Native validation worker exceeded the 768 MiB sampled memory budget.")
            }
            usleep(20000)
        }
        task.waitUntilExit(); group.wait()
        if cancelled.value {throw CLIError(code:"cancelled",message:"Cancelled.",exitCode:130)}
        let (bytes,exceeded)=response.result
        guard !exceeded, let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any], object["ok"] is Bool else {throw CLIError(code:"tool.worker_protocol",message:"Native worker returned invalid or oversized output (exit \(task.terminationStatus)).",exitCode:3)}
        guard task.terminationStatus == 0 || object["ok"] as? Bool != true else { throw CLIError(code:"tool.worker_crash",message:"Native worker terminated abnormally.",exitCode:3) }
        return object
    }
    static func openDirectory(_ url:URL,create:Bool) throws -> Int32 {
        var path=url.standardizedFileURL.path
        for (alias,real) in [("/tmp","/private/tmp"),("/var","/private/var"),("/etc","/private/etc")] {
            if path == alias || path.hasPrefix(alias+"/") {path=real+path.dropFirst(alias.count); break}
        }
        var parent=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard parent >= 0 else {throw CLIError(code:"output.path",message:"Unable to open filesystem root.",exitCode:2)}
        do {
            for component in path.split(separator:"/") {
                let name=String(component)
                if create, mkdirat(parent,name,0o700) != 0, errno != EEXIST {throw CLIError(code:"output.mkdir",message:"Unable to create output directory.",exitCode:2)}
                let next=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard next >= 0 else {throw CLIError(code:"output.path",message:"Output directory contains a symlink or cannot be opened.",exitCode:2)}
                close(parent); parent=next
            }
            return parent
        } catch {close(parent); throw error}
    }
    static func createSafeDirectory(_ url:URL) throws {let fd=try openDirectory(url,create:true); close(fd)}
    static func writeExclusive(_ data:Data,to url:URL) throws {
        let parent=try openDirectory(url.deletingLastPathComponent(),create:false)
        defer {close(parent)}
        let fd=openat(parent,url.lastPathComponent,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else {throw CLIError(code:"output.write",message:"Output exists or cannot be safely created.",exitCode:2)}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        do {try file.write(contentsOf:data); try file.synchronize()} catch {unlinkat(parent,url.lastPathComponent,0); throw error}
    }
}
