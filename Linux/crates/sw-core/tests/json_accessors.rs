//! The lenient JSON accessors. Ported from `JsonTests.cs`, for the part of
//! the Windows `Json` helper that `sw_core::json` has: `OptLong`, `Append`
//! and the nullable `Quote` have no counterpart here.

use serde_json::{Value, json};
use sw_core::json::{Object, ObjectExt, as_f64, as_text, parse_object, quote, stringify, stringify_object};

fn object(value: Value) -> Object {
    match value {
        Value::Object(object) => object,
        other => panic!("not an object: {other}"),
    }
}

#[test]
fn numbers_read_the_same_whether_parsed_or_built_in_memory() {
    let parsed = parse_object(r#"{"i":15,"d":1.5,"s":"42","b":true,"n":null}"#).unwrap();
    let built = object(json!({ "i": 15, "d": 1.5, "s": "42", "b": true, "n": null, "l": 9_000_000_000i64, "f": 2.5f32 }));
    for json in [&parsed, &built] {
        assert_eq!(json.opt_i32("i", 0), 15);
        assert_eq!(json.opt_f64("d"), 1.5);
        assert_eq!(json.opt_i32("s", 0), 42);
        assert_eq!(json.opt_i32("b", 7), 7);
        assert_eq!(json.opt_i32("n", 7), 7);
        assert_eq!(json.opt_i32("missing", 7), 7);
    }
    assert_eq!(built.opt_f64("l"), 9_000_000_000.0);
    assert_eq!(built.opt_f64("f"), 2.5);
    assert!(built.opt_f64("missing").is_nan());
    // A number too large for the type saturates instead of wrapping.
    assert_eq!(built.opt_i32("l", 0), i32::MAX);
}

#[test]
fn text_accessors_convert_scalars_like_org_json() {
    let json = object(json!({ "s": "text", "i": 3, "b": false, "o": {}, "a": [], "n": null }));
    assert_eq!(json.opt_string("s"), "text");
    assert_eq!(json.opt_string("i"), "3");
    assert_eq!(json.opt_string("b"), "false");
    assert_eq!(json.opt_string_or_none("o"), None);
    assert_eq!(json.opt_string_or_none("a"), None);
    assert_eq!(json.opt_string_or_none("n"), None);
    assert_eq!(json.opt_string("o"), "");
    assert_eq!(json.opt_string_or_none("missing"), None);
    assert!(json.is_null("n"));
    assert!(json.is_null("missing"));
    assert!(!json.is_null("s"));
    assert!(json.has("n") && !json.has("missing"));
    assert_eq!(as_text(&json!(1.5)).as_deref(), Some("1.5"));
    assert_eq!(as_f64(&json!(" 2.5 ")), Some(2.5));
    assert_eq!(as_f64(&json!("two")), None);
}

#[test]
fn booleans_objects_and_arrays_are_read_leniently() {
    let json = object(json!({ "t": true, "text": "TRUE", "no": "false", "n": 1, "o": { "k": 1 }, "a": [1, 2] }));
    assert!(json.opt_bool("t", false));
    assert!(json.opt_bool("text", false));
    assert!(!json.opt_bool("no", true));
    assert!(json.opt_bool("n", true) && !json.opt_bool("n", false));
    assert!(json.opt_bool("missing", true));
    assert_eq!(json.opt_object("o").map(|object| object.len()), Some(1));
    assert_eq!(json.opt_array("a").map(Vec::len), Some(2));
    assert!(json.opt_object("a").is_none() && json.opt_array("o").is_none());
}

#[test]
fn stringify_keeps_non_ascii_text_readable() {
    assert_eq!(stringify(&json!({ "a": "你好 <b> & 'c'" })), r#"{"a":"你好 <b> & 'c'"}"#);
    assert_eq!(quote("line\nbreak"), "\"line\\nbreak\"");
    assert_eq!(stringify(&Value::Null), "null");
    assert_eq!(stringify(&json!([{ "k": 1 }, "text", null])), r#"[{"k":1},"text",null]"#);
}

#[test]
fn objects_keep_the_order_of_their_members() {
    let parsed = parse_object(r#"{"z":1,"a":2,"m":3}"#).unwrap();
    assert_eq!(parsed.keys().collect::<Vec<_>>(), ["z", "a", "m"]);
    assert_eq!(stringify_object(&parsed), r#"{"z":1,"a":2,"m":3}"#);
}

#[test]
fn only_a_well_formed_object_parses() {
    for text in ["", "[]", "1", "\"text\"", "null", "{", "{\"a\":1,}", "{\"a\":1} x", "{'a':1}", "{\"a\":1 /* c */}", "{a:1}"] {
        assert!(parse_object(text).is_err(), "{text:?}");
    }
    assert!(parse_object(" {\"a\":[1,{\"b\":null}]} ").is_ok());
}
