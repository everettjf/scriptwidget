//! Package names. Ported from `PackageNamesTests.cs`, itself
//! `testNamesPreserveUnicodeButRejectDirectoryAndCacheEscapes` and
//! `packageNames.test.js`.

use sw_core::packages::names;

fn repeat(text: &str, count: usize) -> String {
    text.repeat(count)
}

#[test]
fn rejects_names_that_could_become_traversal_or_reserved_cache_paths() {
    // The Windows list also holds a name with an unpaired surrogate, which a Rust string cannot hold.
    let invalid = [
        "".to_owned(),
        " ".into(),
        "\t\n".into(),
        ".".into(),
        "..".into(),
        "../outside".into(),
        "/outside".into(),
        "folder/child".into(),
        "folder\\child".into(),
        "__Build".into(),
        "__BUILD".into(),
        "__build".into(),
        ".hidden".into(),
        "name\0bad".into(),
        "name\nbad".into(),
        "name\u{202E}bad".into(),
        "C:relative".into(),
        "c:\\windows".into(),
        repeat("a", 81),
        repeat("😀", 61),
        repeat("漢", 80) + "x",
    ];
    for name in invalid {
        assert!(!names::is_valid(&name), "{name:?}");
    }
}

#[test]
fn accepts_unicode_display_names() {
    // "Ratio 16:9" is in the Android list and not in the Windows one: only Win32 reads a colon as stream syntax.
    let valid = [
        "My Widget".to_owned(),
        "阅读记录".into(),
        "👩‍💻 Focus".into(),
        "e\u{301}".into(),
        repeat("e\u{301}", 80),
        repeat("😀", 60),
        "Foo.Bar".into(),
        repeat("a", 80),
        repeat("漢", 80),
        "Ratio 16:9".into(),
        "Ratio 16-9".into(),
        "Build".into(),
        "__Builder".into(),
        "नमस्ते\u{200D}क".into(),
    ];
    for name in valid {
        assert!(names::is_valid(&name), "{name:?}");
    }
}

#[test]
fn byte_limit_applies_independently_of_grapheme_limit() {
    // 61 four-byte scalars are 244 UTF-8 bytes; joined into fewer graphemes they still exceed 240 bytes.
    assert!(!names::is_valid(&repeat("😀", 61)));
    assert!(names::is_valid(&repeat("漢", 80)));
    assert_eq!(repeat("漢", 80).len(), 240);
}

#[test]
fn identity_folds_case_and_unicode_normalization() {
    assert_eq!(names::identity("Café"), names::identity("CAFE\u{301}"));
    assert_eq!(names::identity("__BUILD"), "__build");
    assert_ne!(names::identity("Widget"), names::identity("Widget 2"));
    // Compared in upper case, as NTFS does: the long s and the Kelvin sign meet their ASCII letters.
    assert_eq!(names::identity("s"), names::identity("\u{17F}"));
    assert_eq!(names::identity("k"), names::identity("\u{212A}"));
    assert_eq!(names::identity("STRASSE"), names::identity("strasse"));
}

#[test]
fn suffix_truncates_the_stem_by_graphemes_to_keep_limits() {
    assert_eq!(names::with_suffix("Widget", " (1)"), "Widget (1)");
    let long_name = repeat("a", 80);
    assert_eq!(names::with_suffix(&long_name, " (1)"), repeat("a", 76) + " (1)");
    assert_eq!(names::with_suffix(&long_name, " Remix"), repeat("a", 74) + " Remix");
    let wide = names::with_suffix(&repeat("漢", 80), " (10000)");
    assert!(names::is_valid(&wide), "{wide}");
    assert!(wide.ends_with(" (10000)"));
    assert_eq!(names::grapheme_count(&wide), 72 + 8);
    assert_eq!(names::with_suffix(&repeat("e\u{301}", 80), " (1)"), repeat("e\u{301}", 76) + " (1)");
    // A family emoji is one grapheme of many bytes: the byte limit shortens the stem further.
    let family = names::with_suffix(&repeat("👨‍👩‍👧‍👦", 12), " (1)");
    assert!(names::is_valid(&family) && family.ends_with(" (1)"), "{family}");
    assert_eq!(names::grapheme_count(&family), 9 + 4);
}

#[test]
fn legacy_identifiers_and_archive_roots_match_the_shared_engine() {
    assert_eq!(names::legacy_id("My Widget!"), "legacy.my-widget");
    assert_eq!(names::legacy_id("阅读记录"), "legacy.widget");
    assert_eq!(names::legacy_id("  A--b  2 "), "legacy.a-b-2");
    assert_eq!(names::archive_root_name("Ratio 16:9"), "Ratio 16-9");
    assert_eq!(names::archive_root_name("..."), "Widget");
    assert_eq!(names::archive_root_name("a/b\\c*d?e\"f<g>h|i"), "a-b-c-d-e-f-g-h-i");
    assert_eq!(names::archive_root_name(&repeat("a", 100)), repeat("a", 80));
    // 80 UTF-16 units, never half a pair: forty emoji.
    assert_eq!(names::archive_root_name(&repeat("😀", 50)), repeat("😀", 40));
}

#[test]
fn control_and_format_characters_are_found_except_the_joiners() {
    for text in ["a\u{0}b", "a\u{1F}b", "a\u{7F}b", "a\u{85}b", "a\u{202E}b", "a\u{200B}b", "a\u{FEFF}b", "a\u{E0001}b"] {
        assert!(names::has_control_characters(text), "{text:?}");
    }
    for text in ["plain", "a\u{200C}b", "a\u{200D}b", "阅读 👩‍💻", "e\u{301}"] {
        assert!(!names::has_control_characters(text), "{text:?}");
    }
}
