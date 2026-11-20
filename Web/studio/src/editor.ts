import { closeBrackets, closeBracketsKeymap, autocompletion, completionKeymap, snippet } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { javascript } from "@codemirror/lang-javascript";
import { bracketMatching, foldGutter, foldKeymap, indentOnInput } from "@codemirror/language";
import { lintGutter, linter } from "@codemirror/lint";
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState, type Extension } from "@codemirror/state";
import {
  EditorView, crosshairCursor, drawSelection, dropCursor, highlightActiveLine, highlightActiveLineGutter,
  highlightSpecialChars, hoverTooltip, keymap, lineNumbers, rectangularSelection,
} from "@codemirror/view";
import { scriptWidgetCompletions, useSnippets } from "../../../Editor/editorfe/src/scriptWidgetCompletions.js";
import { scriptWidgetDiagnostics, scriptWidgetHover } from "../../../Editor/editorfe/src/scriptWidgetLanguage.js";
import { studioTheme } from "../../../Editor/editorfe/src/studioTheme.js";
import { visualLayoutEditor } from "../../../Editor/editorfe/src/visualLayoutEditor.js";
import { setVisualLayoutResources } from "../../../Editor/editorfe/src/visualAssets.js";

useSnippets(snippet);

export interface StudioEditor {
  readonly view: EditorView;
  /// The path shown in the editor, or null before the first open.
  readonly currentPath: string | null;
  open(path: string, text: string): void;
  reset(): void;
  forget(path: string): void;
  focus(): void;
  setTheme(mode: "light" | "dark"): void;
  setResources(paths: string[]): void;
  destroy(): void;
}

/// One EditorState per file keeps undo history when switching files.
export function createEditor(parent: HTMLElement, onChange: (path: string, text: string) => void, mode: "light" | "dark"): StudioEditor {
  const states = new Map<string, EditorState>();
  const theme = new Compartment();
  let themeMode = mode;
  let currentPath: string | null = null;
  const extensions = (path: string): Extension[] => {
    const script = /\.(jsx?|mjs)$/i.test(path);
    return [
      lineNumbers(), highlightActiveLineGutter(), highlightSpecialChars(), history(), foldGutter(), drawSelection(), dropCursor(),
      EditorState.allowMultipleSelections.of(true), indentOnInput(), bracketMatching(), closeBrackets(), rectangularSelection(),
      crosshairCursor(), highlightActiveLine(), highlightSelectionMatches(), EditorView.lineWrapping,
      javascript({ jsx: /\.jsx$/i.test(path) || !/\.json$/i.test(path), typescript: false }),
      ...(script ? [autocompletion({ override: [scriptWidgetCompletions] }), linter(scriptWidgetDiagnostics, { delay: 300 }), lintGutter(), hoverTooltip(scriptWidgetHover)] : []),
      ...(script ? [visualLayoutEditor()] : []),
      keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap, ...completionKeymap, indentWithTab]),
      theme.of(studioTheme(themeMode)),
      EditorView.contentAttributes.of({ "aria-label": `Edit ${path}` }),
      EditorView.updateListener.of((update) => { if (update.docChanged && currentPath === path) onChange(path, update.state.doc.toString()); }),
    ];
  };
  const view = new EditorView({ parent });
  return {
    view,
    get currentPath() { return currentPath; },
    open(path, text) {
      if (currentPath !== null) states.set(currentPath, view.state);
      let state = states.get(path);
      if (!state || state.doc.toString() !== text) state = EditorState.create({ doc: text, extensions: extensions(path) });
      currentPath = path;
      view.setState(state);
    },
    reset() { states.clear(); currentPath = null; },
    forget(path) { states.delete(path); },
    focus() { view.focus(); },
    setResources(paths) { setVisualLayoutResources(view, paths); },
    setTheme(next) {
      if (next === themeMode) return;
      themeMode = next;
      // Stored states keep their own compartment value; drop them so other
      // files reopen with the new theme.
      states.clear();
      view.dispatch({ effects: theme.reconfigure(studioTheme(next)) });
    },
    destroy() { view.destroy(); },
  };
}
