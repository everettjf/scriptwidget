import { useEffect, useMemo, useRef } from "react";
import { createEditor, type StudioEditor } from "@/editor.ts";
import { resourceURLs, type Project } from "@/project.ts";
import type { SaveState } from "@/hooks/useProjects.ts";

const saveLabels: Record<SaveState, string> = {
  idle: "",
  editing: "Editing…",
  saved: "Saved in this browser",
  unavailable: "Browser storage is unavailable; export to keep your work.",
};

interface EditorPaneProps {
  project: Project;
  path: string;
  saveState: SaveState;
  colorScheme: "light" | "dark";
  onChange(path: string, text: string): void;
  onShowTutorial?(): void;
}

/// CodeMirror for text files; binary resources show their size and, for
/// images, a preview instead of being opened as text.
export function EditorPane({ project, path, saveState, colorScheme, onChange, onShowTutorial }: EditorPaneProps) {
  const host = useRef<HTMLDivElement>(null);
  const editor = useRef<StudioEditor | null>(null);
  const changeHandler = useRef(onChange);
  changeHandler.current = onChange;
  const value = project.files[path];
  const isText = typeof value === "string";

  useEffect(() => {
    if (!host.current) return;
    const instance = createEditor(host.current, (file, text) => changeHandler.current(file, text), colorScheme);
    editor.current = instance;
    return () => { instance.destroy(); editor.current = null; };
    // Created once; theme changes go through setTheme.
  }, []);

  useEffect(() => { editor.current?.setTheme(colorScheme); }, [colorScheme]);

  // A new project starts with fresh per-file undo histories.
  useEffect(() => { editor.current?.reset(); }, [project.id]);

  // Open the file, or reload it when its text changed outside the editor
  // (for example, renaming the project rewrites widget.json).
  useEffect(() => {
    const instance = editor.current;
    if (!instance || typeof value !== "string") return;
    if (instance.currentPath !== path || instance.view.state.doc.toString() !== value) instance.open(path, value);
  }, [project.id, path, value]);

  useEffect(() => { editor.current?.setResources(Object.keys(project.files)); }, [project.id, project.files, path, value]);

  const imageURL = useMemo(() => (value instanceof Uint8Array ? resourceURLs({ [path]: value })[path] : undefined), [path, value]);

  return (
    <section className="isolate flex min-h-0 min-w-0 flex-col bg-card" aria-label="Editor">
      <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 border-b px-3 py-1.5 text-xs">
        <span id="current-file" className="truncate font-medium">{path}</span>
        <span id="save-state" className="text-muted-foreground" aria-live="polite">{saveLabels[saveState]}</span>
        {onShowTutorial && <button type="button" className="rounded-sm text-primary underline-offset-2 hover:underline focus-visible:outline-2 focus-visible:outline-ring min-[1101px]:hidden" onClick={onShowTutorial}>Back to tutorial</button>}
      </div>
      <div id="editor" ref={host} className={isText ? "min-h-0 flex-1 overflow-hidden" : "hidden"} tabIndex={-1} />
      {value instanceof Uint8Array && (
        <div className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-sm text-muted-foreground">
          {imageURL && <img src={imageURL} alt={path} className="max-h-64 max-w-full rounded-lg border object-contain" />}
          <p>{path} is a binary file ({value.length.toLocaleString()} bytes).</p>
        </div>
      )}
    </section>
  );
}
