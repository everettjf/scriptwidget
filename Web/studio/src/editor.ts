import { closeBrackets, closeBracketsKeymap, autocompletion, completionKeymap, snippet } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { javascript } from "@codemirror/lang-javascript";
import { bracketMatching, foldGutter, foldKeymap, HighlightStyle, indentOnInput, syntaxHighlighting } from "@codemirror/language";
import { lintGutter, linter } from "@codemirror/lint";
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState, type Extension } from "@codemirror/state";
import {
  EditorView, crosshairCursor, drawSelection, dropCursor, highlightActiveLine, highlightActiveLineGutter,
  highlightSpecialChars, hoverTooltip, keymap, lineNumbers, rectangularSelection,
} from "@codemirror/view";
import { tags } from "@lezer/highlight";
import { scriptWidgetCompletions, useSnippets } from "../../../Editor/editorfe/src/scriptWidgetCompletions.js";
import { scriptWidgetDiagnostics, scriptWidgetHover } from "../../../Editor/editorfe/src/scriptWidgetLanguage.js";
import { studioTheme } from "../../../Editor/editorfe/src/studioTheme.js";
import { visualLayoutEditor } from "../../../Editor/editorfe/src/visualLayoutEditor.js";
import { setVisualLayoutResources } from "../../../Editor/editorfe/src/visualAssets.js";

useSnippets(snippet);

const editorThemes = {
  light: [studioTheme("light"), syntaxHighlighting(HighlightStyle.define([{ tag: tags.tagName, class: "sw-light-tag" }]))],
  dark: studioTheme("dark"),
};

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
      // A queued completion from the previous file can still run after setState.
      // Keep its state available in other files without offering suggestions there.
      autocompletion({ override: script ? [scriptWidgetCompletions] : [], activateOnTyping: script, defaultKeymap: script }),
      ...(script ? [linter(scriptWidgetDiagnostics, { delay: 300 }), lintGutter(), hoverTooltip(scriptWidgetHover)] : []),
      ...(script ? [visualLayoutEditor()] : []),
      keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap, ...(script ? completionKeymap : []), indentWithTab]),
      theme.of(editorThemes[themeMode]),
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
      const effects = theme.reconfigure(editorThemes[next]);
      // Reconfigure stored files too, keeping their edits, selections and undo history.
      for (const [path, state] of states) states.set(path, state.update({ effects }).state);
      view.dispatch({ effects });
    },
    destroy() { view.destroy(); },
  };
}
