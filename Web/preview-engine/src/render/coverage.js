// Coverage matrix for the web renderer. Every tag in the native
// ScriptWidgetElementView switch and every property a native builder reads
// has an entry; test/coverage.test.js derives both lists from the Swift
// sources and fails when one is missing. States: supported, approximated
// (with the known difference), unsupported.

const s = (note = "") => ({ state: "supported", note });
const fontProps = () => ({ fontWeight: { state: "supported", note: "Overrides the weight in font" }, weight: { state: "supported", note: "Older alias of fontWeight" }, fontDesign: { state: "supported", note: "default, rounded, serif, monospaced" } });
const a = (note) => ({ state: "approximated", note });
const u = (note) => ({ state: "unsupported", note });

/// ScriptWidgetAttributeGeneralModifier plus ScriptWidgetElementView.widgetURL.
export const generalProps = Object.freeze({
  padding: s("String values only, as on iPhone: \"10\", \"horizontal,8\", \"t,r,b,l\""),
  frame: s("Includes the native quirk: \"max,20\" sets only the height"),
  background: s("Color or $gradient; on the root element it becomes the widget container background"),
  backgroundMaterial: a("Public SwiftUI material approximated with CSS backdrop blur; Reduce Transparency uses an opaque fallback and accented/vibrant modes omit local material. Not Home Screen wallpaper blur or system Liquid Glass."),
  corner: s(),
  clip: s(),
  opacity: s(),
  animation: a("Public scheduled native clock/swing effects use CSS approximations here. Signed custom half-turn periods and fixed poses match native. Reduce Motion freezes the preview; WidgetKit cadence is system-controlled."),
  rotation: s(),
  rotation3d: a("CSS perspective differs from SwiftUI's"),
  shadow: a("Blur radius mapped to CSS drop-shadow; edges may differ slightly"),
  widgetAccentable: a("Only affects accented rendering mode, which the web preview does not emulate yet"),
  linkurl: s("Tap targets are not interactive in the preview"),
});

export const coverage = Object.freeze({
  tags: {
    vstack: { state: "supported", props: { alignment: s(), spacing: s("Default spacing measured on iOS 27") } },
    hstack: { state: "supported", props: { alignment: s(), spacing: s() } },
    zstack: { state: "supported", props: {} },
    list: { state: "supported", note: "Scrolls on Android only. iPhone, iPad and Mac draw the rows that fit, from the top and at their own heights, and so does the preview; at most 100 rows", props: { spacing: s("Gap between rows; default 0") } },
    hgrid: { state: "approximated", note: "Lazy grid tracks; cells are centered", props: { columns: s("fixed, flexible, adaptive"), alignment: a("Cells are centered"), spacing: s() } },
    vgrid: { state: "approximated", note: "Lazy grid tracks; cells are centered", props: { columns: s("fixed, flexible, adaptive"), alignment: a("Cells are centered"), spacing: s() } },
    text: { state: "supported", props: { ...fontProps(), font: s("SF metrics on Apple systems; fallback fonts elsewhere"), color: s(), alignment: s() } },
    date: { state: "approximated", note: "Real clock like iPhone; English formats", props: { ...fontProps(), date: s("now, tomorrow, yesterday, start of today, +Nh, -Nd, or milliseconds"), style: a("English formats; timers do not tick"), font: s(), color: s(), alignment: s() } },
    image: { state: "approximated", note: "Package images render; SF Symbols use look-alike icons; remote URLs show placeholders", props: {
      systemName: a("Look-alike Lucide icon"), name: s("Needs the package image file"), id: s("Alias of name"), url: a("data: PNG/JPEG only; remote URLs are not loaded"),
      src: a("Alias of url"), ratio: s("With mode fit or fill"), mode: s(), font: s(), ...fontProps(), accentedRenderingMode: a("Accented mode is not emulated"),
    } },
    gif: { state: "approximated", note: "Bounded browser GIF playback; Reduce Motion/Mac and resource limits use a static frame. Native timing differs", props: { file: s("Resolved like ScriptWidgetPackage.getGifFile"), font: s(), ...fontProps() } },
    spacer: { state: "supported", props: {} },
    rect: { state: "supported", props: { corner: s(), trim: a("Trim applies to strokes only"), stroke: s(), color: s() } },
    capsule: { state: "supported", props: { trim: a("Trim applies to strokes only"), stroke: s(), color: s() } },
    ellipse: { state: "supported", props: { trim: a("Trim applies to strokes only"), stroke: s(), color: s() } },
    circle: { state: "supported", props: { trim: a("Trim applies to strokes only"), stroke: s(), color: s() } },
    gauge: { state: "approximated", note: "Original gauge drawn like MineGaugeView; system gauge styles approximated", props: {
      ...Object.fromEntries(["value", "angle", "label", "needleColor", "sections", "thickness", "title", "labelFont", "labelColor", "titleColor"].map((key) => [key, s()])),
      ...Object.fromEntries(["current", "max", "min", "style", "text", "type"].map((key) => [key, a("System gauge styles are approximated")])),
      titleFont: { state: "supported", note: "Not read natively; the title uses labelFont" },
    } },
    chart: { state: "approximated", note: "SVG approximation of Swift Charts marks, axes, and legend", props: Object.fromEntries(["category", "hideLegend", "hideXAxis", "hideYAxis", "data", "type", "color"].map((key) => [key, a("Swift Charts styling differs")])) },
    link: { state: "approximated", note: "Children laid out vertically; not interactive", props: { url: s() } },
    divider: { state: "supported", props: { thickness: s(), axis: s(), color: s() } },
    line: { state: "supported", props: { thickness: s(), length: s(), axis: s(), color: s() } },
    roundedrect: { state: "supported", props: { radius: s(), color: s() } },
    icon: { state: "approximated", note: "SF Symbols are drawn with look-alike Lucide icons (ISC); unmapped names show a placeholder", props: { ...fontProps(), systemName: a("Look-alike Lucide icon"), size: s(), color: s(), font: s() } },
    label: { state: "approximated", note: "Icon is a look-alike Lucide icon", props: { ...fontProps(), title: s(), systemName: a("Look-alike Lucide icon"), color: s(), font: s() } },
    progress: { state: "supported", props: { value: s(), total: s(), label: s(), style: s(), color: s(), trackColor: s(), thickness: s(), frame: s("Circular size") } },
    ring: { state: "supported", props: { value: s(), thickness: s(), color: s(), trackColor: s() } },
    badge: { state: "supported", props: { text: s(), radius: s(), background: s(), color: s() } },
    chip: { state: "supported", props: { text: s(), radius: s(), background: s(), borderColor: s(), color: s() } },
    stat: { state: "supported", props: { title: s(), value: s(), subtitle: s(), color: s(), mutedColor: s() } },
    button: { state: "approximated", note: "Label only; taps run on iPhone", props: { action: s(), actionID: s(), onClick: s() } },
    toggle: { state: "approximated", note: "Static switch on iOS, static checkbox on macOS", props: { on: s(), actionID: s(), onClick: s(), stateKey: s() } },
    Fragment: { state: "supported", props: {} },
  },
});

// Tags whose native builder does not apply ScriptWidgetAttributeGeneralModifier.
const withoutGeneral = new Set(["spacer", "Fragment"]);

/// Reason a property has no effect on iPhone, or null when it is read.
export function ignoredProp(tag, key) {
  const entry = coverage.tags[tag];
  if (!entry) return null;
  if (Object.prototype.hasOwnProperty.call(entry.props, key)) return null;
  if (tag === "spacer") return key === "frame" ? null : "is ignored by the native runtime (Spacer reads only frame)";
  if (!withoutGeneral.has(tag) && Object.prototype.hasOwnProperty.call(generalProps, key)) return null;
  if (key === "key" || key === "children") return null;
  return "is ignored by the native runtime";
}
