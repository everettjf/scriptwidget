// Compile production pure validators/grants and their actual XCTest cases.
// No app host, account, HealthKit query, network or system write is invoked.
import {execFile} from "node:child_process";
import {promisify} from "node:util";
import {mkdtemp,readFile,writeFile,rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join,resolve} from "node:path";
import {fileURLToPath} from "node:url";
const exec=promisify(execFile), repo=fileURLToPath(new URL("..",import.meta.url));
const temporary=await mkdtemp(join(tmpdir(),"scriptwidget-system-tests-"));
const read=path=>readFile(resolve(repo,path),"utf8");
function section(source,start,end){const a=source.indexOf(start),b=end?source.indexOf(end,a):source.length;if(a<0||b<=a)throw Error(`Source boundary changed: ${start}`);return source.slice(a,b);}
try{
 const developer=(await exec("xcode-select",["-p"])).stdout.trim();
 const platform=join(developer,"Platforms/MacOSX.platform/Developer"),frameworks=join(platform,"Library/Frameworks"),libraries=join(platform,"usr/lib");
 const services=await read("Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeSystemServices.swift");
 const packages=await read("Shared/ScriptWidgetRuntime/Common/ScriptWidgetPackage.swift");
 let helpers="import Foundation\nimport Darwin\nimport CryptoKit\n"+section(packages,"enum ScriptWidgetMetadataFile {","/// Keeps private execution resources")
  +section(services,"enum ScriptWidgetSystemServiceError:","struct ScriptWidgetSystemServiceContext")
  +section(services,"enum ScriptWidgetSystemOptions {","protocol ScriptWidgetSystemMutationRequest")
  +section(services,"protocol ScriptWidgetSystemMutationRequest {","extension ScriptWidgetReminderMutation")
  +section(services,"struct ScriptWidgetNativeMutation:",null);
 for(const [file,start,end] of [["Notifications","struct ScriptWidgetNotificationOptions","@objc protocol"],["CalendarWrites","struct ScriptWidgetCalendarMutation","enum ScriptWidgetRuntimeCalendarWrites"],["HealthHistory","struct ScriptWidgetHealthHistoryOptions","enum ScriptWidgetRuntimeHealthHistory"],["Alarms","struct ScriptWidgetAlarmOptions","@objc protocol"],["Documents","enum ScriptWidgetDocumentData","@objc protocol"],["Weather","struct ScriptWidgetWeatherOptions","@objc protocol"]])helpers+=section(await read(`Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntime${file}.swift`),start,end);
 await writeFile(join(temporary,"helpers.swift"),helpers);
 const testSource=(await read("Tests/ScriptWidgetRuntimeTests/SystemServiceTests.swift")).replace("@testable import ScriptWidget","");
 await writeFile(join(temporary,"main.swift"),testSource+`\nlet suite=SystemServiceTests.defaultTestSuite\nsuite.run()\nguard let run=suite.testRun,run.executionCount>=8,run.totalFailureCount==0 else {exit(1)}\n`);
 const binary=join(temporary,"tests");
 await exec("xcrun",["swiftc","-F",frameworks,"-I",libraries,"-L",libraries,...[frameworks,libraries,join(platform,"Library/PrivateFrameworks"),resolve(developer,"../SharedFrameworks")].flatMap(p=>["-Xlinker","-rpath","-Xlinker",p]),
 ...["Widget/API/ScriptWidgetStorageLock.swift","Widget/API/ScriptWidgetStorageNamespaces.swift","Common/ScriptWidgetCloudJSON.swift"].map(p=>resolve(repo,"Shared/ScriptWidgetRuntime",p)),join(temporary,"helpers.swift"),join(temporary,"main.swift"),"-o",binary],{timeout:60000});
 const result=await exec(binary,[],{timeout:30000});process.stdout.write(result.stdout+result.stderr);
}catch(error){process.stderr.write(error.stdout??"");process.stderr.write(error.stderr??"");throw error;}finally{await rm(temporary,{recursive:true,force:true});}
