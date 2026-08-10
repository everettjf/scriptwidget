// Editor metadata for the native JSX components selected by
// ScriptWidgetElementView's switch. The native switch remains the runtime
// authority; tests verify that this metadata stays aligned with it.
export const scriptWidgetAPI = {
  "schemaVersion": 1,
  "runtimeVersion": "26.6",
  "documentation": "Public JSX surface shared by ScriptWidget Runtime and Studio.",
  "platforms": {
    "ios": "16.0",
    "macos": "26.0",
    "widgetExtension": "18.0"
  },
  "globalProperties": {
    "background": { "type": "color", "documentation": "Background color, hex value, or named color." },
    "color": { "type": "color", "documentation": "Foreground color, hex value, or named color." },
    "font": { "type": "enum", "values": ["largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout", "footnote", "caption", "caption2"], "documentation": "Semantic text style." },
    "fontWeight": { "type": "enum", "values": ["ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"], "documentation": "Font weight." },
    "fontDesign": { "type": "enum", "values": ["default", "rounded", "serif", "monospaced"], "documentation": "Font design." },
    "frame": { "type": "number|string", "documentation": "Size or frame description." },
    "padding": { "type": "number|string", "documentation": "Padding amount or edge description." },
    "corner": { "type": "number", "documentation": "Corner radius." },
    "opacity": { "type": "number", "documentation": "Opacity from 0 through 1." },
    "alignment": { "type": "enum", "values": ["center", "leading", "trailing", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing", "firstTextBaseline", "lastTextBaseline"], "documentation": "Layout alignment." },
    "clip": { "type": "enum", "values": ["circle", "rect", "capsule", "ellipse"], "documentation": "Clip the view to a shape." },
    "rotation": { "type": "number", "documentation": "Rotation in degrees." },
    "rotation3d": { "type": "string", "documentation": "3D rotation description." },
    "shadow": { "type": "string", "documentation": "Shadow color, radius, and offset description." },
    "animation": { "type": "string", "documentation": "Timeline-driven animation description." },
    "widgetAccentable": { "type": "boolean", "documentation": "Group this view into the accent layer in tinted and vibrant widget appearances." },
    "linkurl": { "type": "url", "documentation": "Widget deep link URL." }
  },
  "components": {
    "VStack": { "documentation": "Arrange children vertically.", "children": true, "properties": { "spacing": { "type": "number" } } },
    "HStack": { "documentation": "Arrange children horizontally.", "children": true, "properties": { "spacing": { "type": "number" } } },
    "ZStack": { "documentation": "Overlay children.", "children": true, "properties": {} },
    "VGrid": { "documentation": "Vertical lazy grid.", "children": true, "properties": { "columns": { "type": "string", "required": true }, "spacing": { "type": "number" }, "alignment": { "type": "enum", "values": ["leading", "center", "trailing"] } } },
    "HGrid": { "documentation": "Horizontal lazy grid.", "children": true, "properties": { "columns": { "type": "string", "required": true }, "spacing": { "type": "number" }, "alignment": { "type": "enum", "values": ["top", "center", "bottom", "firstTextBaseline", "lastTextBaseline"] } } },
    "Text": { "documentation": "Display text content.", "children": false, "properties": { "text": { "type": "string" } } },
    "Date": { "documentation": "Display a formatted date.", "children": false, "properties": { "date": { "type": "date|number", "required": true }, "style": { "type": "enum", "values": ["time", "date", "relative", "offset", "timer"] } } },
    "Image": { "documentation": "Display a bundled, remote, or SF Symbol image.", "children": false, "properties": { "systemName": { "type": "string" }, "name": { "type": "string" }, "id": { "type": "string", "deprecated": "Use name." }, "url": { "type": "url" }, "src": { "type": "url", "deprecated": "Use url." }, "ratio": { "type": "number" }, "mode": { "type": "enum", "values": ["fit", "fill"] }, "accentedRenderingMode": { "type": "enum", "values": ["accented", "desaturated", "accentedDesaturated", "fullColor"], "documentation": "Control how the image is rendered in tinted and clear widget appearances." } } },
    "Gif": { "documentation": "Display a GIF from the package.", "children": false, "properties": { "file": { "type": "string", "required": true } } },
    "Spacer": { "documentation": "Flexible layout space.", "children": false, "properties": { "minLength": { "type": "number" } } },
    "Rect": { "documentation": "Rectangle shape.", "children": false, "properties": { "trim": { "type": "number|string" }, "stroke": { "type": "string" } } },
    "RoundedRect": { "documentation": "Filled rounded rectangle.", "children": false, "properties": { "radius": { "type": "number" } } },
    "Capsule": { "documentation": "Capsule shape.", "children": false, "properties": { "trim": { "type": "number|string" }, "stroke": { "type": "string" } } },
    "Ellipse": { "documentation": "Ellipse shape.", "children": false, "properties": { "trim": { "type": "number|string" }, "stroke": { "type": "string" } } },
    "Circle": { "documentation": "Circle shape.", "children": false, "properties": { "trim": { "type": "number|string" }, "stroke": { "type": "string" } } },
    "Gauge": { "documentation": "Display a gauge or instrument.", "children": false, "properties": { "type": { "type": "string" }, "value": { "type": "number" }, "style": { "type": "enum", "values": ["circular", "linear"] }, "text": { "type": "string" }, "current": { "type": "string" }, "min": { "type": "string" }, "max": { "type": "string" }, "angle": { "type": "number" }, "thickness": { "type": "number" }, "needleColor": { "type": "color" }, "label": { "type": "string" }, "title": { "type": "string" }, "sections": { "type": "string" } } },
    "Chart": { "documentation": "Render chart data.", "children": false, "availability": { "ios": "16.0", "macos": "26.0" }, "properties": { "type": { "type": "enum", "values": ["bar", "bar-x", "bar-y", "bar-gantt", "line", "point", "line-point", "area", "rect", "rule-x"] }, "data": { "type": "json", "required": true }, "category": { "type": "boolean" }, "hideLegend": { "type": "boolean" }, "hideXAxis": { "type": "boolean" }, "hideYAxis": { "type": "boolean" } } },
    "Link": { "documentation": "Open a URL when selected.", "children": true, "properties": { "url": { "type": "url", "required": true } } },
    "Divider": { "documentation": "Horizontal or vertical separator.", "children": false, "properties": { "thickness": { "type": "number" }, "axis": { "type": "enum", "values": ["horizontal", "vertical"] } } },
    "Line": { "documentation": "Fixed-length line.", "children": false, "properties": { "thickness": { "type": "number" }, "length": { "type": "number" }, "axis": { "type": "enum", "values": ["horizontal", "vertical"] } } },
    "Icon": { "documentation": "SF Symbol icon.", "children": false, "properties": { "systemName": { "type": "string", "required": true }, "size": { "type": "number" } } },
    "Label": { "documentation": "Text paired with an SF Symbol.", "children": false, "properties": { "title": { "type": "string" }, "systemName": { "type": "string", "required": true } } },
    "Progress": { "documentation": "Linear or circular progress.", "children": false, "properties": { "value": { "type": "number", "required": true }, "total": { "type": "number" }, "label": { "type": "string" }, "style": { "type": "enum", "values": ["linear", "circular"] }, "trackColor": { "type": "color" }, "thickness": { "type": "number" } } },
    "Ring": { "documentation": "Circular progress ring.", "children": false, "properties": { "value": { "type": "number", "required": true }, "thickness": { "type": "number" }, "trackColor": { "type": "color" } } },
    "Badge": { "documentation": "Compact status badge.", "children": false, "properties": { "text": { "type": "string" }, "radius": { "type": "number" } } },
    "Chip": { "documentation": "Outlined metadata chip.", "children": false, "properties": { "text": { "type": "string" }, "radius": { "type": "number" }, "borderColor": { "type": "color" } } },
    "Stat": { "documentation": "Title, value, and subtitle statistic.", "children": false, "properties": { "title": { "type": "string" }, "value": { "type": "string", "required": true }, "subtitle": { "type": "string" }, "mutedColor": { "type": "color" } } },
    "Button": { "documentation": "Interactive widget button on iOS 17 and later.", "children": true, "availability": { "interactiveIos": "17.0" }, "properties": { "action": { "type": "enum", "values": ["reload"] }, "onClick": { "type": "function" } } },
    "Toggle": { "documentation": "Interactive widget toggle on iOS 17 and later.", "children": true, "availability": { "interactiveIos": "17.0" }, "properties": { "on": { "type": "boolean", "required": true }, "onClick": { "type": "function", "required": true } } }
  },
  "functions": {
    "fetch": { "documentation": "Perform a network request." },
    "importJS": { "documentation": "Import a package-relative JavaScript file." },
    "$dataSource.request": { "documentation": "Call a declared Data Source Plugin operation. Requires Package 2.0 plugins, network permission, and networkDomains declarations.", "arguments": ["pluginID", "operationID", "parameters"], "returns": "Promise<json|string>" }
  },
  "environmentValues": ["widgetFamily", "scriptName", "scriptParameter", "widget-rendering-mode", "live-activity-state", "live-activity-surface"]
};
