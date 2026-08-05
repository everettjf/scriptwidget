import { EditorView } from "@codemirror/view";
import { defaultHighlightStyle, syntaxHighlighting } from "@codemirror/language";

const palette = {
  light: {
    background: "#FAFAFC",
    foreground: "#202124",
    gutter: "#F3F3F6",
    gutterText: "#8A8A93",
    activeLine: "#EDEEF3",
    selection: "#B9D7FF",
    caret: "#0067C0",
  },
  dark: {
    background: "#1E1F22",
    foreground: "#E8E8ED",
    gutter: "#191A1D",
    gutterText: "#777982",
    activeLine: "#292A2F",
    selection: "#315A85",
    caret: "#65B7FF",
  },
};

function editorTheme(colors, dark) {
  return EditorView.theme(
    {
      "&": {
        height: "100%",
        color: colors.foreground,
        backgroundColor: colors.background,
        fontSize: "13px",
      },
      ".cm-scroller": {
        fontFamily: 'ui-monospace, "SFMono-Regular", Menlo, Monaco, Consolas, monospace',
        lineHeight: "1.58",
        overscrollBehavior: "contain",
      },
      ".cm-content": {
        caretColor: colors.caret,
        padding: "12px 0 32px",
      },
      ".cm-line": { padding: "0 8px" },
      ".cm-cursor, .cm-dropCursor": { borderLeftColor: colors.caret },
      "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": {
        backgroundColor: colors.selection,
      },
      ".cm-activeLine": { backgroundColor: colors.activeLine },
      ".cm-gutters": {
        backgroundColor: colors.gutter,
        color: colors.gutterText,
        border: "none",
        paddingLeft: "env(safe-area-inset-left)",
      },
      ".cm-activeLineGutter": {
        backgroundColor: colors.activeLine,
        color: colors.foreground,
      },
      ".cm-foldPlaceholder": {
        backgroundColor: "transparent",
        border: `1px solid ${colors.gutterText}`,
        color: colors.gutterText,
      },
      ".cm-tooltip": {
        border: dark ? "1px solid #41434A" : "1px solid #D2D3D8",
        backgroundColor: dark ? "#292A2F" : "#FFFFFF",
        borderRadius: "8px",
        overflow: "hidden",
        boxShadow: "0 8px 28px rgba(0, 0, 0, 0.2)",
      },
      ".cm-tooltip-autocomplete ul li[aria-selected]": {
        backgroundColor: dark ? "#315A85" : "#DCEBFA",
        color: colors.foreground,
      },
      ".cm-panels": {
        backgroundColor: colors.gutter,
        color: colors.foreground,
      },
      ".cm-searchMatch": { backgroundColor: dark ? "#725C1D" : "#FFE69A" },
      ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: dark ? "#8D6D20" : "#FFD45C" },
    },
    { dark }
  );
}

export function studioTheme(mode) {
  const isDark = mode === "dark";
  return [
    editorTheme(isDark ? palette.dark : palette.light, isDark),
    syntaxHighlighting(defaultHighlightStyle),
  ];
}
