//! The check for tags and attributes ScriptWidget does not have. Ported from
//! `AiJsxCheckTest.kt`, which mirrors the Swift tests: the same code must get
//! the same sentences on every system. Its loop cases are in `ai_agent_loop.rs`.

use std::path::{Path, PathBuf};

use sw_core::ai::jsx_check::{AiJsxCheck, Surface};

fn problems(source: &str) -> Vec<String> {
    AiJsxCheck::problems(source, AiJsxCheck::linux())
}

fn android() -> Surface {
    AiJsxCheck::parse_surface(AiJsxCheck::surface_text(), Some("android"))
}

const NONE: [&str; 0] = [];

#[test]
fn a_widget_that_uses_only_what_exists_has_no_problem() {
    let source = r##"// <nothing here="x"> is a tag
const title = "a <b c> in a string";
const wide = count<limit && other < 3;
$render(
  <vstack frame="max" alignment="leading" background="#0a84ff" padding="16" spacing="6" {...extra}>
    <text font="title,bold" weight="bold" fontDesign="rounded" color={dark ? "white" : "black"}>It's {title}</text>
    <date date={new Date()} style="timer" />
    <date date={now} style={"relative"} />
    {rows.map((row) => <hstack key={row.id}><Card title={row.title} flavour="x" /></hstack>)}
    <image systemName="sun.max" mode="fit" clip="circle" />
  </vstack>,
);
"##;
    assert_eq!(problems(source), NONE);
    assert_eq!(AiJsxCheck::summary(source, AiJsxCheck::linux()), None);
}

#[test]
fn an_attribute_or_value_or_tag_that_does_not_exist_is_named() {
    let weekday = problems("$render(<date date={now} style=\"weekday\" />)");
    assert_eq!(weekday.len(), 1);
    assert!(weekday[0].contains("style=\"weekday\"") && weekday[0].contains("time, date, relative, offset, timer"), "{}", weekday[0]);
    let format = problems("$render(<vstack><date date={now} format=\"EEEE\" /></vstack>)");
    assert!(format[0].contains("<date> has no attribute \"format\"") && format[0].contains("style"), "{}", format[0]);
    let tag = problems("$render(<row><text>a</text></row>)");
    assert!(tag[0].contains("<row> is not a ScriptWidget tag") && tag[0].contains("vstack"), "{}", tag[0]);
    assert!(problems("return <text fontWeight={\"huge\"}>a</text>")[0].contains("fontWeight=\"huge\""));
    assert_eq!(problems("$render(<text fontWeight={weight}>a</text>)"), NONE, "a value that is computed is not judged");
    assert!(AiJsxCheck::summary("$render(<row/>)", AiJsxCheck::linux()).unwrap().starts_with("The code uses tags or attributes that ScriptWidget does not have:\n- "));
}

/// The three spellings the DeepSeek batch run produced, and the rest of the frame grammar. Same text as the Swift and Kotlin tests.
#[test]
fn a_frame_the_runtime_would_not_read_is_named() {
    let auto = problems("$render(<vstack><hstack frame=\"max,auto\" spacing=\"6\"><text>a</text></hstack></vstack>)");
    assert_eq!(
        auto,
        ["frame=\"max,auto\" on <hstack> is not a frame ScriptWidget reads; it would be ignored or centered. \
Write it without spaces as one of: \"max\", \"max,leading\", \"60\", \"60,40\", \"60,40,leading\", \
\"max,40\", \"max,40,leading\", \"60,max\", \"60,max,leading\". The alignments are: center, leading, trailing, top, bottom, \
topLeading, topTrailing, bottomLeading, bottomTrailing. There is no \"auto\": for a row as wide as the widget \
and as tall as its content, put a <spacer/> inside an <hstack>."]
    );
    for read in ["max", "max,center", "max,leading", "max,max", "60", "12.5", "0", "36,4", "max,24", "60,max", "60,40,topLeading", "max,24,bottomTrailing", "60,max,trailing", "10,,20"] {
        assert!(AiJsxCheck::frame_is_read(read), "{read}");
        assert_eq!(problems(&format!("$render(<vstack frame=\"{read}\"></vstack>)")), NONE, "{read}");
    }
    for dropped in ["", "auto", "-4", "max,", "max,auto", "max, leading", "60, 60", "60,leading", "leading,max", "max,max,center", "60,40,middle", "60,40,center,top", "full", "100%", "1e3"] {
        assert!(!AiJsxCheck::frame_is_read(dropped), "{dropped}");
    }
    assert_eq!(problems("$render(<vstack frame={\"60, 60\"}></vstack>)").len(), 1);
    assert_eq!(problems("$render(<vstack frame={side}><circle frame={48} /><spacer frame=\"8\" /></vstack>)"), NONE, "a value that is computed, or written as a number, is not judged");
    assert_eq!(problems("$render(<vstack><hstack frame=\"max,auto\" /><hstack frame=\"max,auto\" /></vstack>)").len(), 1);
}

#[test]
fn a_tag_inside_a_tag_without_children_is_named() {
    let nested = problems("$render(<vstack><text font=\"caption\"><date date=\"now\" style=\"date\" /></text></vstack>)");
    assert_eq!(nested, ["<text> takes no tags inside it, so the <date> in it is not shown. Put it next to the <text>, not in it."]);
    assert_eq!(problems("$render(<vstack><text>{rows.map((row) => <Row />)} a < b</text><text>Plain {value}</text><date date=\"now\" /></vstack>)"), NONE);
}

#[test]
fn the_same_problem_is_reported_once_and_the_list_is_short() {
    let many: String = (1..=12).map(|number| format!("<text madeUp{number}=\"1\">a</text>")).collect::<String>() + "<text madeUp1=\"1\">a</text>";
    assert_eq!(problems(&format!("$render(<vstack>{many}</vstack>)")).len(), AiJsxCheck::MAX_PROBLEMS);
    assert_eq!(problems("$render(<vstack><row/><row/></vstack>)").len(), 1);
}

/// The scrolling list is marked `@android` in the generated list: a tag there, and not on Linux.
#[test]
fn the_scrolling_list_is_a_tag_on_android_only() {
    let source = "$render(<list spacing=\"4\"><text>a</text></list>)";
    assert_eq!(AiJsxCheck::problems(source, &android()), NONE);
    assert!(problems(source)[0].contains("<list> is not a ScriptWidget tag"));
    let apple = AiJsxCheck::parse_surface(AiJsxCheck::surface_text(), None);
    assert_eq!(&apple, AiJsxCheck::linux(), "Linux has the shared tags and no tag of its own");
    assert!(!problems("$render(<row/>)")[0].contains("list"), "the tags a model is offered do not include it");
}

/// The words of a problem are the ones Android and the Apple apps use, attribute lists included.
#[test]
fn the_sentences_are_the_ones_of_the_other_ports() {
    let surface = AiJsxCheck::parse_surface("global color\nglobal clip=circle|rect\ntag text text\ntag date date style=time|date\ntag@android list spacing\ntag@linux panel width\nleaf text date\n", Some("linux"));
    assert_eq!(AiJsxCheck::problems("$render(<box/>)", &surface), ["<box> is not a ScriptWidget tag. The tags are: text, date, panel."]);
    assert_eq!(AiJsxCheck::problems("$render(<date when=\"x\"/>)", &surface), ["<date> has no attribute \"when\"; it would be ignored. Its attributes are: date, style, color, clip."]);
    assert_eq!(AiJsxCheck::problems("$render(<date style=\"long\" clip=\"oval\"/>)", &surface), [
        "style=\"long\" on <date> is not one of its values; it would be ignored. Use one of: time, date.",
        "clip=\"oval\" on <date> is not one of its values; it would be ignored. Use one of: circle, rect.",
    ]);
    assert_eq!(AiJsxCheck::problems("$render(<panel width=\"3\"/>)", &surface), NONE);
}

fn repository_root() -> PathBuf {
    let mut root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    while !root.join("Shared/ScriptWidgetRuntime/Resource/Script.bundle").is_dir() {
        assert!(root.pop(), "repository root not found");
    }
    root
}

fn collect(folder: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(folder) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.to_string_lossy().contains("__Build") || path.file_name().is_some_and(|name| name == "node_modules") {
            continue;
        }
        if path.is_dir() {
            collect(&path, files);
        } else if path.extension().is_some_and(|extension| extension == "jsx") {
            files.push(path);
        }
    }
}

/// Every template, example and Gallery widget in the repository passes: the check must not cry
/// wolf. The Android-only templates are read as Android reads them; all others as Linux does.
#[test]
fn every_bundled_widget_passes() {
    let root = repository_root();
    let android = android();
    let mut total = 0;
    let mut wrong: Vec<String> = Vec::new();
    for (folder, surface) in [("Shared/ScriptWidgetRuntime/Resource/Script.bundle", AiJsxCheck::linux()), ("Gallery", AiJsxCheck::linux()), ("Scripts", AiJsxCheck::linux()), ("Android/app/src/main/assets/Script.android", &android)] {
        let mut files = Vec::new();
        collect(&root.join(folder), &mut files);
        total += files.len();
        for file in files {
            let found = AiJsxCheck::problems(&std::fs::read_to_string(&file).unwrap_or_default(), surface);
            if !found.is_empty() {
                wrong.push(format!("{}: {}", file.strip_prefix(&root).unwrap().display(), found.iter().map(|text| text.chars().take(110).collect::<String>()).collect::<Vec<_>>().join(" | ")));
            }
        }
    }
    assert!(total > 50, "found {total} widgets");
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
}
