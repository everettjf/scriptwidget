import { readFile, readdir, stat } from "node:fs/promises";
import { join, relative } from "node:path";
import { createHash } from "node:crypto";
import { scriptWidgetAPI } from "../Editor/editorfe/src/scriptWidgetAPI.js";

const root = new URL("../", import.meta.url).pathname;
const templateRoot = join(root, "Shared/ScriptWidgetRuntime/Resource/Script.bundle/template");
const schema = scriptWidgetAPI;
const packageSchema = JSON.parse(await readFile(join(root, "Shared/ScriptWidgetRuntime/Resource/widget.schema.json"), "utf8"));
const skillSchema = JSON.parse(await readFile(join(root, "Shared/ScriptWidgetRuntime/Resource/skill.schema.json"), "utf8"));
const pluginSchema = JSON.parse(await readFile(join(root, "Shared/ScriptWidgetRuntime/Resource/plugin.schema.json"), "utf8"));
const failures = [];
// These component paths must stay on public APIs for distribution. General
// JavaScriptCore bridging elsewhere has a different contract and is not banned.
for (const file of ["Attributes/Animation/ClockHandRotationEffect.swift", "Attributes/Animation/SwingAnimationModifier.swift", "Elements/ScriptWidgetElementTagGif.swift"]) {
  const source = await readFile(join(root, "Shared/ScriptWidgetRuntime/Widget/Component", file), "utf8");
  if (/_typeByName|_ClockHandRotationEffect|unsafeBitCast/.test(source)) failures.push(`${file}: private animation bridge must not be reintroduced`);
}
const names = (await readdir(templateRoot)).sort();
const metadataSource = await readFile(join(root, "Shared/ScriptWidgetRuntime/Common/ScriptMetadata.swift"), "utf8");
const categoryDeclaration = metadataSource.match(/enum ScriptCategory:[\s\S]*?\{([\s\S]*?)\n\s*var id:/)?.[1] ?? "";
const categories = new Set([...categoryDeclaration.matchAll(/\bcase (\w+)/g)].map(match => match[1]));
if (!categories.size) failures.push("Cannot read the native template category contract");

for (const communityFile of ["README_CN.md", "CODE_OF_CONDUCT.md", "GOVERNANCE.md", "CHANGELOG.md", ".github/CODEOWNERS", ".github/dependabot.yml", ".github/ISSUE_TEMPLATE/gallery_submission.yml"]) {
  try { await stat(join(root, communityFile)); }
  catch { failures.push(`missing community health file: ${communityFile}`); }
}

if (names.length < 60) failures.push(`expected at least 60 templates, found ${names.length}`);
for (const name of names) {
  const directory = join(templateRoot, name);
  if (!(await stat(directory)).isDirectory()) continue;
  let source, meta;
  try { source = await readFile(join(directory, "main.jsx"), "utf8"); }
  catch { failures.push(`${name}: missing main.jsx`); continue; }
  try { meta = JSON.parse(await readFile(join(directory, "meta.json"), "utf8")); }
  catch { failures.push(`${name}: invalid or missing meta.json`); continue; }
  for (const key of ["description", "category", "difficulty", "icon"]) {
    if (!meta[key]) failures.push(`${name}: missing ${key}`);
  }
  if (!categories.has(meta.category)) failures.push(`${name}: unknown template category ${meta.category}`);
  if (source.includes("fetch(") && !["weather", "finance", "productivity"].includes(meta.category)) {
    failures.push(`${name}: network template must use a network-related category`);
  }
  if (Buffer.byteLength(source) > 512 * 1024) failures.push(`${name}: source exceeds runtime limit`);
}

const recordBackupSchema = JSON.parse(await readFile(join(root, "Shared/ScriptWidgetRuntime/Resource/record-backup.schema.json"), "utf8"));
if (recordBackupSchema.properties?.formatVersion?.const !== 1 || recordBackupSchema.additionalProperties !== false) {
  failures.push("Record Backup 1 schema must declare its closed versioned envelope");
}
const recordKinds = recordBackupSchema.properties?.kind?.enum ?? [];
const recordBranches = recordBackupSchema.allOf ?? [];
const descriptorKinds = new Set();
for (const name of names) {
  const files = await readdir(join(templateRoot, name));
  if (!files.includes("record-template.json")) continue;
  const descriptor = JSON.parse(await readFile(join(templateRoot, name, "record-template.json"), "utf8"));
  const manifest = JSON.parse(await readFile(join(templateRoot, name, "widget.json"), "utf8"));
  descriptorKinds.add(descriptor.kind);
  const minimumRuntimeVersion = descriptor.kind === "wallpaper" ? "1.4" : "1.3";
  if (descriptor.formatVersion !== 1 || !recordKinds.includes(descriptor.kind) || Object.keys(descriptor).length !== 2 || !manifest.permissions.includes("storage") || manifest.minimumRuntimeVersion !== minimumRuntimeVersion) {
    failures.push(`${name}: record descriptor or storage requirements are invalid`);
  }
}
if (new Set(recordKinds).size !== recordKinds.length || recordKinds.length !== descriptorKinds.size || recordBranches.length !== recordKinds.length) {
  failures.push("Record Backup 1 schema kinds and branches must cover every record template exactly once");
}
for (const kind of recordKinds) {
  const branches = recordBranches.filter((branch) => branch.if?.properties?.kind?.const === kind);
  const values = branches[0]?.then?.properties?.values?.propertyNames?.enum;
  const diagnostics = branches[0]?.then?.properties?.unsupportedValues?.propertyNames?.enum;
  if (!descriptorKinds.has(kind) || branches.length !== 1 || !Array.isArray(values) || !values.includes("recordTemplate.config.v1") || JSON.stringify(values) !== JSON.stringify(diagnostics)) {
    failures.push(`Record Backup 1 ${kind}: missing template, duplicate branch, or mismatched diagnostic key scope`);
  }
}

const generatedDocs = await readFile(join(root, "docs/scriptwidget-runtime-api.md"), "utf8");
if (!generatedDocs.includes(`schema v${schema.schemaVersion}`) || !generatedDocs.includes(`runtime ${schema.runtimeVersion}`)) {
  failures.push("runtime docs do not match schema/runtime version");
}
if (packageSchema.properties?.formatVersion?.const !== 2 || packageSchema.properties?.runtimeVersion?.const !== "1.0") {
  failures.push("Package 2.0 schema does not match the runtime contract");
}
if (skillSchema.properties?.formatVersion?.const !== 1 || skillSchema.properties?.promptFile?.const !== "SKILL.md" || skillSchema.additionalProperties !== false) {
  failures.push("Skills 1.0 schema does not match the fail-closed runtime contract");
}
if (pluginSchema.properties?.formatVersion?.const !== 1 || pluginSchema.additionalProperties !== false) {
  failures.push("Data Source Plugin 1.0 schema does not match the fail-closed runtime contract");
}
const pluginDocs = await readFile(join(root, "docs/data-source-plugins.md"), "utf8");
for (const required of ["plugin.json", ".swplugin", "HTTPS-only", "2 MiB", "cannot read files"]) {
  if (!pluginDocs.includes(required)) failures.push(`Data Source Plugin documentation is missing ${required}`);
}
const pluginSource = await readFile(join(root, "Shared/ScriptWidgetRuntime/Plugin/ScriptWidgetDataSources.swift"), "utf8");
for (const guardrail of ["rejectUnknownFields", "ScriptPackageArchivePreflight", "maximumPackageBytes", "networkDomains", "permissions.contains(.network)"]) {
  if (!pluginSource.includes(guardrail)) failures.push(`Data Source Plugin runtime is missing ${guardrail}`);
}
const skillDocs = await readFile(join(root, "docs/skills.md"), "utf8");
for (const required of ["skill.json", "SKILL.md", ".swskill", "256 KiB", "cannot execute code"]) {
  if (!skillDocs.includes(required)) failures.push(`Skills documentation is missing ${required}`);
}
const tutorialDocs = await readFile(join(root, "docs/five-minute-tutorial.md"), "utf8");
for (const required of ["five-step", "Create Tutorial Widget", "⌘S", "⌘R", "Edit Widgets", "Update iCloud Scripts"]) {
  if (!tutorialDocs.includes(required)) failures.push(`five-minute tutorial documentation is missing ${required}`);
}
const packageDocs = await readFile(join(root, "docs/package-format.md"), "utf8");
for (const required of ["widget.json", "32 MiB", "64 MiB", "symbolic links", "legacy package"]) {
  if (!packageDocs.includes(required)) failures.push(`package documentation is missing ${required}`);
}

const iosInfo = await readFile(join(root, "iOS/ScriptWidget/Info.plist"), "utf8");
for (const key of ["NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription", "NSLocationWhenInUseUsageDescription", "NSAppleMusicUsageDescription"]) {
  if (!iosInfo.includes(`<key>${key}</key>`)) failures.push(`iOS Info.plist is missing ${key}`);
}
const widgetMusicInfo = await readFile(join(root, "iOS/ScriptWidgetWidget/Info.plist"), "utf8");
if (!widgetMusicInfo.includes("<key>NSAppleMusicUsageDescription</key>")) failures.push("iOS widget Info.plist is missing NSAppleMusicUsageDescription");

// Service credentials share a dedicated group; the first/default group must
// remain app-specific so existing AI items never default into the shared group.
const serviceGroup = "$(AppIdentifierPrefix)com.everettjf.scriptwidget.services";
for (const [infoPath, entitlementPath] of [
  ["iOS/ScriptWidget/Info.plist", "iOS/ScriptWidget/ScriptWidget.entitlements"],
  ["iOS/ScriptWidgetWidget/Info.plist", "iOS/ScriptWidgetWidget/ScriptWidgetWidget.entitlements"],
  ["macOS/ScriptWidgetMac/Info.plist", "macOS/ScriptWidgetMac/macOS.entitlements"],
  ["macOS/ScriptWidgetMacWidget/Info.plist", "macOS/ScriptWidgetMacWidget/ScriptWidgetMacWidget.entitlements"],
]) {
  const info = await readFile(join(root, infoPath), "utf8"), entitlements = await readFile(join(root, entitlementPath), "utf8");
  const declaredGroup = info.match(/<key>ScriptWidgetServiceKeychainGroup<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
  const groupBlock = entitlements.match(/<key>keychain-access-groups<\/key>\s*<array>([\s\S]*?)<\/array>/)?.[1] ?? "";
  const groups = [...groupBlock.matchAll(/<string>([^<]+)<\/string>/g)].map(value => value[1]);
  if (declaredGroup !== serviceGroup || (info.match(/<key>ScriptWidgetServiceKeychainGroup<\/key>/g) ?? []).length !== 1) failures.push(`${infoPath}: service Keychain group must match the signed shared service group`);
  if (JSON.stringify(groups) !== JSON.stringify(["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)", serviceGroup]) || (entitlements.match(/<key>keychain-access-groups<\/key>/g) ?? []).length !== 1) failures.push(`${entitlementPath}: preserve the app-specific default group before the dedicated shared service group`);
}

const aiSettings = await readFile(join(root, "Shared/ScriptWidgetRuntime/AI/AISettings.swift"), "utf8");
if (!aiSettings.includes("apiKey is intentionally omitted") || !aiSettings.includes("AIKeychain.live")) {
  failures.push("AI credentials must remain Keychain-backed and omitted from UserDefaults JSON");
}

const packageSource = await readFile(join(root, "Shared/ScriptWidgetRuntime/Common/ScriptWidgetPackage.swift"), "utf8");
for (const guardrail of ["ScriptWidgetPackageFiles.write(data, root: path, relative: relative)", "O_CREAT | O_EXCL | O_NOFOLLOW", "fsync(fd) == 0 && renameat(directory, temporary, directory, name) == 0"]) {
  if (!packageSource.includes(guardrail)) failures.push(`atomic package saves are missing ${guardrail}`);
}
const managerSource = await readFile(join(root, "Shared/ScriptWidgetRuntime/Common/ScriptManager.swift"), "utf8");
for (const guardrail of ["ScriptPackageArchivePreflight", "maximumExpandedBytes", "isSymbolicLinkKey", "WidgetPackageManifestValidator"]) {
  if (!managerSource.includes(guardrail)) failures.push(`secure package import is missing ${guardrail}`);
}
const skillSource = await readFile(join(root, "Shared/ScriptWidgetRuntime/AI/AIWidgetSkills.swift"), "utf8");
for (const guardrail of ["maximumPackageBytes", "ScriptPackageArchivePreflight", 'Set(children) == ["skill.json", "SKILL.md"]', "maximumInstructionBytes"]) {
  if (!skillSource.includes(guardrail)) failures.push(`secure Skill import is missing ${guardrail}`);
}
const onboardingSource = await readFile(join(root, "macOS/ScriptWidgetMac/Onboarding/FirstRunOnboardingView.swift"), "utf8");
for (const requirement of ["currentVersion", "shouldPresent", "Create Tutorial Widget", "MacTutorialStep.allCases", "interactiveDismissDisabled"]) {
  if (!onboardingSource.includes(requirement)) failures.push(`Mac onboarding is missing ${requirement}`);
}

const galleryIndex = JSON.parse(await readFile(join(root, "Gallery/index.json"), "utf8"));
const gallerySchema = JSON.parse(await readFile(join(root, "Gallery/gallery.schema.json"), "utf8"));
if (galleryIndex.schemaVersion !== 1 || gallerySchema.properties?.schemaVersion?.const !== 1 || gallerySchema.additionalProperties !== false) {
  failures.push("Gallery 1.0 index/schema contract is invalid");
}
if (!Array.isArray(galleryIndex.items) || galleryIndex.items.length < 2) failures.push("Gallery must ship widget and Skill seeds");
const galleryIDs = new Set();
for (const item of galleryIndex.items ?? []) {
  if (galleryIDs.has(item.id)) failures.push(`Gallery duplicate id: ${item.id}`);
  galleryIDs.add(item.id);
  const expectedPrefix = `https://raw.githubusercontent.com/everettjf/scriptwidget/main/Gallery/`;
  for (const file of item.files ?? []) {
    if (!file.url.startsWith(expectedPrefix)) { failures.push(`${item.id}/${file.path}: untrusted Gallery URL`); continue; }
    const localPath = join(root, "Gallery", file.url.slice(expectedPrefix.length));
    try {
      const data = await readFile(localPath);
      if (data.length !== file.bytes) failures.push(`${item.id}/${file.path}: byte count mismatch`);
      if (createHash("sha256").update(data).digest("hex") !== file.sha256) failures.push(`${item.id}/${file.path}: SHA-256 mismatch`);
    } catch { failures.push(`${item.id}/${file.path}: indexed file missing`); }
  }
}
const galleryKinds = new Set((galleryIndex.items ?? []).map(item => item.kind));
if (!galleryKinds.has("widget") || !galleryKinds.has("skill")) failures.push("Gallery seeds must include both kinds");
const galleryDocs = await readFile(join(root, "docs/gallery.md"), "utf8");
for (const required of ["trust root", "SHA-256", "If-None-Match", "256 KiB", "curator", "cannot execute code"]) {
  if (!galleryDocs.includes(required)) failures.push(`Gallery documentation is missing ${required}`);
}
const gallerySource = await readFile(join(root, "Shared/ScriptWidgetRuntime/Gallery/ScriptWidgetGallery.swift"), "utf8");
for (const guardrail of ["rejectUnknownFields", "raw.githubusercontent.com", "If-None-Match", "contentFingerprint", "replaceDirectory"]) {
  if (!gallerySource.includes(guardrail)) failures.push(`Gallery runtime is missing ${guardrail}`);
}

const releaseDocs = await readFile(join(root, "docs/release-readiness.md"), "utf8");
for (const command of ["./Scripts/release-readiness.sh", "./Scripts/device-matrix.sh", "./Scripts/ipad-icloud-tests.sh"]) {
  if (!releaseDocs.includes(command)) failures.push(`release documentation is missing ${command}`);
}

async function walk(directory) {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    // "target" is Cargo's build folder: after a local Linux build it holds too many files to walk.
    if (["node_modules", ".git", ".claude", "build", "dist", "target", "StudioEditor.bundle"].includes(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) { for (const inner of await walk(path)) result.push(inner); } else result.push(path);
  }
  return result;
}
for (const path of await walk(root)) {
  if (!/\.(swift|js|jsx|mjs|html)$/.test(path)) continue;
  const contents = await readFile(path, "utf8");
  if (relative(root, path).toLowerCase() !== "scripts/validate-release.mjs" && /monaco-editor|Monaco editor/.test(contents)) {
    failures.push(`${relative(root, path)}: legacy Monaco editor reference`);
  }
}

if (failures.length) {
  console.error(failures.map(value => `✗ ${value}`).join("\n"));
  process.exit(1);
}
console.log(`✓ release metadata, ${names.length} templates, API docs and editor sources validated`);
