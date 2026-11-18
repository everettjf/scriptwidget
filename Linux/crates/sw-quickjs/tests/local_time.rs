//! Local time. This file holds a single test because it changes the time
//! zone of the whole process: Cargo runs each test file as its own program,
//! and with one test nothing else reads the environment at the same time.

use sw_quickjs::{Engine, JS_THREAD_STACK, run_on_js_thread, set_process_time_zone};

fn evaluate(code: &'static str) -> String {
    run_on_js_thread("test-js", JS_THREAD_STACK, move || Engine::new(|_, _| Ok(None)).expect("engine").evaluate(code, "script.js").expect("evaluation").unwrap_or_default())
}

#[test]
fn local_time_uses_the_offset_of_the_date_not_of_today() {
    // SAFETY: the only test of this program; no other thread uses the environment or local time.
    unsafe { set_process_time_zone(Some("America/Los_Angeles")) };
    // Winter and summer of the same year differ by the daylight-saving hour.
    assert_eq!(evaluate("new Date(Date.UTC(2026, 0, 15, 12)).getTimezoneOffset() + ',' + new Date(Date.UTC(2026, 6, 15, 12)).getTimezoneOffset()"), "480,420");
    assert_eq!(evaluate("String(new Date(Date.UTC(2026, 6, 15, 11, 30)).getHours())"), "4");
    // SAFETY: as above.
    unsafe { set_process_time_zone(Some("Asia/Shanghai")) };
    assert_eq!(evaluate("String(new Date(Date.UTC(2026, 6, 15, 12)).getTimezoneOffset())"), "-480");
    // SAFETY: as above.
    unsafe { set_process_time_zone(None) };
}
