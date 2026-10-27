// Run the actual CloudJSON XCTest cases without an app/testmanagerd session.
// Compile unchanged production file helpers and storage services; all fixtures
// are temporary directories. This supplements, never replaces, app-host tests.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const exec = promisify(execFile);
const repo = fileURLToPath(new URL("..", import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), "scriptwidget-cloud-json-"));
try {
  const developer = (await exec("xcode-select", ["-p"])).stdout.trim();
  const platform = join(developer, "Platforms/MacOSX.platform/Developer");
  const frameworks = join(platform, "Library/Frameworks"), libraries = join(platform, "usr/lib");
  const source = await readFile(join(repo, "Shared/ScriptWidgetRuntime/Common/ScriptWidgetPackage.swift"), "utf8");
  const start = source.indexOf("enum ScriptWidgetMetadataFile {"), end = source.indexOf("/// Keeps private execution resources");
  if (start < 0 || end <= start) throw new Error("Production file-helper boundaries changed; update the probe.");
  await writeFile(join(temporary, "helpers.swift"), "import Foundation\nimport Darwin\n" + source.slice(start, end));
  const tests = await readFile(join(repo, "Tests/ScriptWidgetRuntimeTests/PackageCacheTests.swift"), "utf8");
  const testStart = tests.indexOf("final class CloudJSONTests: XCTestCase {");
  if (testStart < 0) throw new Error("Missing CloudJSON fixture tests.");
  await writeFile(join(temporary, "main.swift"), "import XCTest\n" + tests.slice(testStart) + `
let suite = CloudJSONTests.defaultTestSuite
suite.run()
guard let result = suite.testRun, result.executionCount >= 10, result.totalFailureCount == 0 else { exit(1) }
`);
  const binary = join(temporary, "tests");
  await exec("xcrun", ["swiftc", "-F", frameworks, "-I", libraries, "-L", libraries,
    ...[frameworks, libraries, join(platform, "Library/PrivateFrameworks"), resolve(developer, "../SharedFrameworks")]
      .flatMap(path => ["-Xlinker", "-rpath", "-Xlinker", path]),
    ...["Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetStorageLock.swift",
      "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetStorageNamespaces.swift",
      "Shared/ScriptWidgetRuntime/Common/ScriptWidgetCloudJSON.swift"].map(path => resolve(repo, path)),
    join(temporary, "helpers.swift"), join(temporary, "main.swift"), "-o", binary], { timeout: 60000 });
  const result = await exec(binary, [], { timeout: 30000 });
  process.stdout.write(result.stdout + result.stderr);
} catch (error) {
  process.stderr.write(error.stdout ?? "");
  process.stderr.write(error.stderr ?? "");
  throw error;
} finally {
  await rm(temporary, { recursive: true, force: true });
}
