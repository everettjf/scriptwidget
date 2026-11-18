//! The engine binding, ported from Windows/tests/ScriptWidget.Core.Tests/QuickJsTests.cs.

use sw_quickjs::{DEFAULT_MEMORY_LIMIT, DEFAULT_STACK_LIMIT, Engine, HostResult, JS_THREAD_STACK, JsError, run_on_js_thread};

fn on_js_thread<T: Send>(block: impl FnOnce(&mut Engine) -> T + Send) -> T {
    with_host(|_, _| Ok(None), DEFAULT_MEMORY_LIMIT, block)
}

fn with_host<T: Send>(host: impl Fn(&str, Option<&str>) -> HostResult + Send, memory: usize, block: impl FnOnce(&mut Engine) -> T + Send) -> T {
    run_on_js_thread("test-js", JS_THREAD_STACK, move || {
        let mut engine = Engine::with_limits(host, memory, DEFAULT_STACK_LIMIT).expect("engine");
        block(&mut engine)
    })
}

fn evaluate(code: &'static str) -> Result<Option<String>, JsError> {
    on_js_thread(move |engine| engine.evaluate(code, "script.js"))
}

#[test]
fn evaluates_and_returns_strings() {
    assert_eq!(evaluate("[1,2,3].map(x => x * 2).join(',')").unwrap().as_deref(), Some("2,4,6"));
    assert_eq!(evaluate("undefined").unwrap(), None);
    assert_eq!(evaluate("null").unwrap(), None);
    assert_eq!(evaluate("''").unwrap().as_deref(), Some(""));
}

#[test]
fn keeps_astral_characters_and_replaces_lone_surrogates() {
    assert_eq!(evaluate("'你好 🌤️'").unwrap().as_deref(), Some("你好 🌤️"));
    // A Rust string cannot hold a lone surrogate; it arrives as one U+FFFD.
    assert_eq!(evaluate("'a\\ud83db'").unwrap().as_deref(), Some("a\u{fffd}b"));
    let echoed = on_js_thread(|engine| {
        engine.evaluate("globalThis.echo = (text) => text + '|' + text.length;", "script.js").unwrap();
        engine.call("echo", &[Some("a🌤b")])
    });
    assert_eq!(echoed.unwrap().as_deref(), Some("a🌤b|4"));
}

#[test]
fn source_text_may_contain_nul_characters() {
    assert_eq!(evaluate("'a\0b'.length + ''").unwrap().as_deref(), Some("3"));
}

#[test]
fn top_level_declarations_are_visible_to_later_scripts() {
    let value = on_js_thread(|engine| {
        engine.evaluate("const a = 1; let b = 2; class C {}", "first.js").unwrap();
        engine.evaluate("String(a + b)", "second.js")
    });
    assert_eq!(value.unwrap().as_deref(), Some("3"));
}

#[test]
fn calls_functions_with_null_arguments() {
    let value = on_js_thread(|engine| {
        engine.evaluate("globalThis.f = (a, b) => String(a) + '|' + b;", "script.js").unwrap();
        engine.call("f", &[None, Some("x")])
    });
    assert_eq!(value.unwrap().as_deref(), Some("null|x"));
}

#[test]
fn runs_promise_jobs() {
    let value = on_js_thread(|engine| {
        engine.evaluate("globalThis.r = 'pending'; (async () => { r = await Promise.resolve('done'); })();", "script.js").unwrap();
        assert!(engine.run_jobs(10_000).unwrap() > 0);
        engine.evaluate("r", "script.js")
    });
    assert_eq!(value.unwrap().as_deref(), Some("done"));
}

#[test]
fn host_calls_return_values_null_and_errors() {
    fn host(operation: &str, payload: Option<&str>) -> HostResult {
        match operation {
            "echo" => Ok(payload.map(str::to_owned)),
            "null" => Ok(None),
            "panic" => panic!("host panicked"),
            other => Err(format!("host refused {other}")),
        }
    }
    let run = |code: &'static str| with_host(host, DEFAULT_MEMORY_LIMIT, move |engine| engine.evaluate(code, "script.js")).unwrap();
    assert_eq!(run("__swNative('echo', 'payload ✓')").as_deref(), Some("payload ✓"));
    assert_eq!(run("String(__swNative('echo') === null)").as_deref(), Some("true"));
    assert_eq!(run("String(__swNative('null') === null)").as_deref(), Some("true"));
    assert_eq!(run("try { __swNative('other'); 'no error' } catch (error) { error.message }").as_deref(), Some("host refused other"));
    // A panic in the host becomes a JavaScript error instead of unwinding through the interpreter.
    assert_eq!(run("try { __swNative('panic'); 'no error' } catch (error) { error.message }").as_deref(), Some("native host error"));
}

#[test]
fn uncaught_errors_carry_message_and_stack() {
    let error = on_js_thread(|engine| engine.evaluate("function boom() { throw new TypeError('bad thing'); } boom();", "widget.js")).unwrap_err();
    assert!(!error.interrupted);
    assert!(error.message.contains("TypeError: bad thing"), "{}", error.message);
    assert!(error.message.contains("widget.js"), "{}", error.message);
}

#[test]
fn deadline_interrupts_an_endless_loop() {
    let error = on_js_thread(|engine| {
        engine.set_deadline(200);
        engine.evaluate("for (;;) {}", "script.js")
    })
    .unwrap_err();
    assert!(error.interrupted);
}

#[test]
fn clearing_the_deadline_lets_later_code_run() {
    let value = on_js_thread(|engine| {
        engine.set_deadline(100);
        assert!(engine.evaluate("for (;;) {}", "script.js").is_err());
        engine.set_deadline(0);
        engine.evaluate("'ok'", "script.js")
    });
    assert_eq!(value.unwrap().as_deref(), Some("ok"));
}

#[test]
fn memory_limit_stops_runaway_allocation() {
    let error = with_host(|_, _| Ok(None), 16 * 1024 * 1024, |engine| engine.evaluate("const a = []; for (;;) a.push(new Array(100000).fill(1));", "script.js")).unwrap_err();
    assert!(error.message.to_lowercase().contains("out of memory"), "{}", error.message);
}

#[test]
fn deep_recursion_raises_a_range_error() {
    let error = evaluate("function f() { return f() + 1 } f()").unwrap_err();
    assert!(error.message.to_lowercase().contains("stack"), "{}", error.message);
}

#[test]
fn bytecode_round_trips() {
    let bytes = on_js_thread(|engine| engine.compile("globalThis.answer = 6 * 7; String(answer)", "script.js")).unwrap();
    assert!(!bytes.is_empty());
    // SAFETY: the bytecode was produced by `compile` of this build a line above.
    let value = on_js_thread(move |engine| unsafe { engine.evaluate_bytecode(&bytes) });
    assert_eq!(value.unwrap().as_deref(), Some("42"));
}

#[test]
fn reports_memory_in_use() {
    assert!(on_js_thread(|engine| engine.memory_used()) > 0);
}

#[test]
fn the_engine_has_no_system_interfaces() {
    let value = evaluate("['std', 'os', 'bjson', 'print', 'require', 'process', 'console', 'fetch', 'setTimeout'].filter((name) => name in globalThis).join(',')");
    assert_eq!(value.unwrap().as_deref(), Some(""));
}
