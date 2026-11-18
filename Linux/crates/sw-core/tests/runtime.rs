//! The compiler, the executor and the native APIs working together on small
//! packages. Needs the assets of `node Linux/scripts/build-shared-js.mjs`.

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use sw_core::api::{StorageModule, system};
use sw_core::compiler::PrepareOptions;
use sw_core::{ExecutionRequest, ExecutionResult, MemoryPackageFiles, NativeModule, PackageCompiler, ScriptExecutor, SharedScripts};

fn scripts() -> Arc<SharedScripts> {
    static SCRIPTS: OnceLock<Arc<SharedScripts>> = OnceLock::new();
    SCRIPTS.get_or_init(|| Arc::new(SharedScripts::new(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/scriptwidget")).expect("shared scripts"))).clone()
}

fn compiler() -> &'static PackageCompiler {
    static COMPILER: OnceLock<PackageCompiler> = OnceLock::new();
    COMPILER.get_or_init(|| PackageCompiler::new(scripts()).expect("compiler thread"))
}

fn package(files: &[(&str, &str)]) -> MemoryPackageFiles {
    MemoryPackageFiles::new(files.iter().map(|(path, text)| (path.to_string(), text.to_string())), [])
}

struct Run<'a> {
    files: &'a MemoryPackageFiles,
    modules: Vec<Arc<dyn NativeModule>>,
    package_id: &'a str,
    environments: &'a [(&'a str, &'a str)],
    timeout_milliseconds: u64,
}

impl<'a> Run<'a> {
    fn new(files: &'a MemoryPackageFiles) -> Self {
        Self { files, modules: Vec::new(), package_id: "test", environments: &[], timeout_milliseconds: 5000 }
    }

    fn execute(self) -> ExecutionResult {
        let prepared = compiler().prepare(self.files, &PrepareOptions::default()).expect("prepare");
        let mut request = ExecutionRequest::new(&prepared, self.files);
        request.system = Some(system::system_info());
        request.modules = self.modules;
        request.package_id = self.package_id.to_owned();
        request.timeout_milliseconds = self.timeout_milliseconds;
        request.environments.extend(self.environments.iter().map(|(name, value)| (name.to_string(), value.to_string())));
        ScriptExecutor::new(scripts()).execute(&request)
    }
}

fn tree(result: &ExecutionResult) -> &str {
    result.tree.as_deref().unwrap_or_else(|| panic!("no tree: {:?}", result.error))
}

/// A directory of its own for one test's storage.
fn storage_directory(name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!("scriptwidget-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    directory
}

#[test]
fn renders_jsx_to_the_canonical_tree() {
    let files = package(&[("main.jsx", "$render(<vstack><text font=\"title\">Hello 你好 🌤️</text></vstack>);")]);
    assert_eq!(
        tree(&Run::new(&files).execute()),
        r#"{"$element":"vstack","props":null,"children":[{"$element":"text","props":{"font":"title"},"children":["Hello 你好 🌤️"]}]}"#
    );
}

#[test]
fn the_platform_is_linux() {
    let files = package(&[("main.jsx", "$render(<text>{$system.platform()}</text>);")]);
    assert!(tree(&Run::new(&files).execute()).contains(r#""children":["linux"]"#));
}

#[test]
fn imports_and_package_files_stay_inside_the_package() {
    let files = package(&[
        ("main.jsx", "$import('lib/label.js'); $render(<text>{label($file.readJSON('data.json').name)}|{$file.read('../../etc/passwd')}|{String($file.exists('/etc/passwd'))}</text>);"),
        ("lib/label.js", "function label(name) { return 'name=' + name; }"),
        ("data.json", r#"{"name":"widget"}"#),
    ]);
    let result = Run::new(&files).execute();
    assert!(tree(&result).contains(r#""children":["name=widget","|","","|","false"]"#), "{}", tree(&result));
}

#[test]
fn storage_persists_per_package_and_is_bounded() {
    let directory = storage_directory("storage");
    let module = Arc::new(StorageModule::new(&directory));
    let run = |package_id: &str, code: &str| {
        let files = package(&[("main.jsx", code)]);
        let result = Run { modules: vec![module.clone()], package_id, ..Run::new(&files) }.execute();
        tree(&result).to_owned()
    };
    let write = "$render(<text>{String($storage.setString('count', '7'))},{String($storage.setJSON('record', {a: 1}))},{String($storage.setString('big', 'x'.repeat(300000)))}</text>);";
    assert!(run("first", write).contains(r#"["true",",","true",",","false"]"#));
    let read = "$render(<text>{$storage.getString('count')}|{JSON.stringify($storage.getJSON('record'))}|{$storage.keys().join(',')}</text>);";
    assert!(run("first", read).contains(r#"["7","|","{\"a\":1}","|","count,record"]"#));
    // Another package sees none of it.
    assert!(run("second", read).contains(r#"["","|","{}","|",""]"#));
    assert_eq!(module.get_string("first", "count"), "7");

    let cas = "$render(<text>{String($storage.compareAndSetString('count', '1', '2'))},{String($storage.compareAndSetString('count', '7', '8'))},{$storage.getString('count')}</text>);";
    assert!(run("first", cas).contains(r#"["false",",","true",",","8"]"#));

    // Files are private to the user and named by a hash, not by the package.
    use std::os::unix::fs::PermissionsExt;
    let entries: Vec<_> = std::fs::read_dir(&directory).unwrap().map(|entry| entry.unwrap()).collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].metadata().unwrap().permissions().mode() & 0o777, 0o600);
    assert!(!entries[0].file_name().to_string_lossy().contains("first"));
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn timeline_projections_cannot_write_storage() {
    let directory = storage_directory("projection");
    let module = Arc::new(StorageModule::new(&directory));
    let files = package(&[("main.jsx", "$render(<text>{String($storage.setString('key', 'value'))}</text>);")]);
    let result = Run { modules: vec![module.clone()], environments: &[("timeline-is-projection", "true")], ..Run::new(&files) }.execute();
    assert!(tree(&result).contains(r#"["false"]"#), "{}", tree(&result));
    assert!(module.snapshot("test").is_empty());
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn an_endless_loop_ends_with_a_resource_limit_error() {
    let files = package(&[("main.jsx", "for (;;) {}")]);
    let result = Run { timeout_milliseconds: 300, ..Run::new(&files) }.execute();
    assert_eq!(result.tree, None);
    assert_eq!(result.error.map(|error| error.kind).as_deref(), Some("resourceLimit"));
    assert!(result.elapsed.as_millis() < 3000, "{:?}", result.elapsed);
}

#[test]
fn runaway_allocation_ends_with_a_resource_limit_error() {
    let files = package(&[("main.jsx", "const all = []; for (;;) all.push(new Array(100000).fill(1));")]);
    let result = Run::new(&files).execute();
    assert_eq!(result.tree, None);
    let error = result.error.expect("error");
    assert_eq!(error.kind, "resourceLimit", "{}", error.message);
}

#[test]
fn package_code_cannot_reach_the_native_entry_points() {
    let files = package(&[(
        "main.jsx",
        "$render(<text>{[typeof __swNative, typeof __swEvaluate, typeof __swBoot, typeof __swKernel, Object.getOwnPropertyNames(globalThis).filter((name) => name.startsWith('__sw')).map((name) => name.replace(/[0-9a-f]{32}$/, '<token>')).join('+')].join(',')}</text>);",
    )]);
    // The driver the host calls is the only name left. It is not enumerable, and it can only
    // pump, resolve and time out the execution that is already running.
    let result = Run::new(&files).execute();
    assert!(tree(&result).contains(r#"["undefined,undefined,undefined,undefined,__sw_<token>"]"#), "{}", tree(&result));
}

#[test]
fn unsupported_apis_say_so() {
    let files = package(&[("main.jsx", "$render(<text>{String($health.isAvailable())}</text>); $health.stepCountToday();")]);
    let result = Run::new(&files).execute();
    match (&result.tree, &result.error) {
        (_, Some(error)) => assert!(error.message.contains("is not supported on Linux"), "{}", error.message),
        (Some(tree), None) => assert!(tree.contains(r#"["false"]"#), "{tree}"),
        (None, None) => panic!("neither tree nor error"),
    }
}

#[test]
fn a_malformed_manifest_fails_closed() {
    let files = package(&[("main.jsx", "$render(<text>hi</text>);"), ("widget.json", "{ not json")]);
    let error = compiler().prepare(&files, &PrepareOptions::default()).expect_err("a damaged manifest must not be read as a legacy package");
    assert!(!error.kind.is_empty());
    let report = compiler().validate_manifest("{ not json", &["main.jsx".into(), "widget.json".into()]).expect("validator");
    assert_eq!(report.get("ok").and_then(|value| value.as_bool()), Some(false));
}

#[test]
fn intl_formats_with_the_system_icu() {
    let files = package(&[(
        "main.jsx",
        "const d = new Date(Date.UTC(2026, 0, 15, 20, 5));\n$render(<text>{[new Intl.NumberFormat('en-US').format(1234567.891), new Intl.NumberFormat('de-DE', {style: 'currency', currency: 'EUR'}).format(12.5), d.toLocaleDateString('en-US', {timeZone: 'UTC', dateStyle: 'medium'}), new Intl.DateTimeFormat('en-US', {timeZone: 'Asia/Tokyo', hour: '2-digit', minute: '2-digit'}).format(d), new Intl.PluralRules('en-US').select(1), new Intl.RelativeTimeFormat('en', {numeric: 'auto'}).format(-1, 'day'), new Intl.ListFormat('en', {type: 'conjunction'}).format(['a', 'b', 'c']), 'a'.localeCompare('b', 'en')].join(';')}</text>);",
    )]);
    let result = Run::new(&files).execute();
    assert!(tree(&result).contains("1,234,567.891;12,50\u{a0}€;Jan 15, 2026;05:05 AM;one;yesterday;a, b, and c;-1"), "{}", tree(&result));
}
