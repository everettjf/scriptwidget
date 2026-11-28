import { useCallback, useEffect, useRef, useState } from "react";
import { createProject, initialPath, packageReport, type Project } from "@/project.ts";
import { preferences, storage } from "@/store.ts";
import type { PackageFiles } from "../../../preview-engine/src/types.js";

export type SaveState = "idle" | "editing" | "saved" | "unavailable";

export interface ProjectsModel {
  ready: boolean;
  createdStarter: boolean;
  projects: Project[];
  project: Project | null;
  path: string;
  saveState: SaveState;
  openProject(project: Project): void;
  addProject(project: Project): Promise<void>;
  removeProject(id: string): Promise<void>;
  openFile(path: string): void;
  /// Replaces files; null removes a path.
  updateFiles(changes: Record<string, string | Uint8Array | null>): void;
  updateProjectFiles(id: string, expectedFiles: PackageFiles, changes: Record<string, string | Uint8Array | null>): boolean;
  rename(name: string): void;
  setFixtures(text: string): void;
  updateTutorial(expected: Project, change: Pick<Project, "tutorial"> & { fixtures?: string }): boolean;
}

const byRecent = (a: Project, b: Project) => b.updatedAt - a.updatedAt;

/// Projects stored in this browser and the one being edited. Edits are saved
/// 400 ms after the last change and when the page is hidden.
export function useProjects(): ProjectsModel {
  const [ready, setReady] = useState(false);
  const [createdStarter, setCreatedStarter] = useState(false);
  const [projects, setProjects] = useState<Project[]>([]);
  const [project, setProject] = useState<Project | null>(null);
  const [path, setPath] = useState("main.jsx");
  const [saveState, setSaveState] = useState<SaveState>("idle");
  const dirty = useRef(false);
  const latest = useRef<Project | null>(null);
  const drafts = useRef(new Map<string, Project>());
  const dirtyProjects = useRef(new Set<string>());
  const deletingProjects = useRef(new Set<string>());
  const pending = useRef(new Map<Project, Promise<void>>());

  const persist = useCallback((snapshot: Project): Promise<void> => {
    const existing = pending.current.get(snapshot);
    if (existing) return existing;
    if (deletingProjects.current.has(snapshot.id) || drafts.current.get(snapshot.id) !== snapshot) return Promise.resolve();
    const task = (async () => {
      const saved = await storage.save(snapshot);
      // An older completion must not clear a newer edit, resurrect a removed
      // project, or mark another project's draft as saved.
      if (deletingProjects.current.has(snapshot.id) || drafts.current.get(snapshot.id) !== snapshot) return;
      drafts.current.set(saved.id, saved);
      dirtyProjects.current.delete(saved.id);
      setProjects((list) => list.map((item) => item.id === saved.id ? saved : item));
      if (latest.current === snapshot) {
        latest.current = saved;
        dirty.current = false;
        setProject(saved);
      }
      // Do not display Saved on a different open project while an outgoing
      // draft is still waiting for its own durable write.
      setSaveState(!storage.persistent ? "unavailable" : dirtyProjects.current.size ? "editing" : "saved");
    })().finally(() => { pending.current.delete(snapshot); });
    pending.current.set(snapshot, task);
    return task;
  }, []);

  const openProject = useCallback((next: Project) => {
    if (dirty.current && latest.current) void persist(latest.current);
    const current = drafts.current.get(next.id) ?? next;
    drafts.current.set(current.id, current);
    dirty.current = dirtyProjects.current.has(current.id);
    latest.current = current;
    preferences.write("project", current.id);
    setProject(current);
    setPath(initialPath(current));
    setSaveState(!storage.persistent ? "unavailable" : dirtyProjects.current.size ? "editing" : "saved");
  }, [persist]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      let list = (await storage.list()).sort(byRecent);
      if (list.length === 0) {
        const starter = createProject("My First Widget");
        await storage.save(starter);
        list = [starter];
        if (!cancelled) setCreatedStarter(true);
      }
      if (cancelled) return;
      drafts.current = new Map(list.map((item) => [item.id, item]));
      setProjects(list);
      const lastID = preferences.read<string | null>("project", null);
      openProject(list.find((item) => item.id === lastID) ?? list[0]!);
      setReady(true);
      if (!storage.persistent) setSaveState("unavailable");
    })();
    return () => { cancelled = true; };
  }, [openProject]);

  // Debounce only the current revision; switching flushes its snapshot first.
  useEffect(() => {
    if (!project || !dirtyProjects.current.has(project.id)) return;
    const timer = setTimeout(() => { void persist(project); }, 400);
    return () => clearTimeout(timer);
  }, [project, persist]);

  useEffect(() => {
    const flush = () => {
      for (const id of dirtyProjects.current) {
        const snapshot = drafts.current.get(id);
        if (snapshot) void persist(snapshot);
      }
    };
    const onVisibility = () => { if (document.visibilityState === "hidden") flush(); };
    window.addEventListener("beforeunload", flush);
    document.addEventListener("visibilitychange", onVisibility);
    return () => { window.removeEventListener("beforeunload", flush); document.removeEventListener("visibilitychange", onVisibility); };
  }, [persist]);

  const edit = useCallback((change: (current: Project) => Project, saveNow = false) => {
    const current = latest.current;
    if (!current || drafts.current.get(current.id) !== current) return false;
    dirty.current = true;
    const next = change(current);
    latest.current = next;
    drafts.current.set(next.id, next);
    dirtyProjects.current.add(next.id);
    setProjects((list) => list.map((item) => item.id === next.id ? next : item));
    setProject(next);
    setSaveState(storage.persistent ? "editing" : "unavailable");
    if (saveNow) void persist(next);
    return true;
  }, [persist]);

  const addProject = useCallback(async (next: Project) => {
    const saved = await storage.save(next);
    drafts.current.set(saved.id, saved);
    setProjects((list) => [saved, ...list.filter((item) => item.id !== saved.id)]);
    openProject(saved);
  }, [openProject]);

  const removeProject = useCallback(async (id: string) => {
    if (deletingProjects.current.has(id)) return;
    deletingProjects.current.add(id);
    try {
      await storage.remove(id);
      // Keep the draft until deletion commits. An aborted transaction must
      // preserve both the project and edits made while the result was pending.
      drafts.current.delete(id);
      dirtyProjects.current.delete(id);
      if (latest.current?.id === id) dirty.current = false;
      let remaining = [...drafts.current.values()];
      if (remaining.length === 0) {
        const saved = await storage.save(createProject());
        drafts.current.set(saved.id, saved);
        remaining = [...drafts.current.values()];
      }
      setProjects(remaining);
      if (latest.current?.id === id) { latest.current = null; openProject(remaining[0]!); }
    } finally {
      deletingProjects.current.delete(id);
      const retained = drafts.current.get(id);
      if (retained && dirtyProjects.current.has(id)) void persist(retained);
    }
  }, [openProject, persist]);

  const updateFiles = useCallback((changes: Record<string, string | Uint8Array | null>) => {
    edit((current) => {
      const files: PackageFiles = { ...current.files };
      for (const [name, value] of Object.entries(changes)) {
        if (value === null) delete files[name]; else files[name] = value;
      }
      return { ...current, files };
    });
  }, [edit]);

  // Async authoring dialogs must commit to the same project and file snapshot
  // they reviewed, never to whichever project happens to be open later.
  const updateProjectFiles = useCallback((id: string, expectedFiles: PackageFiles, changes: Record<string, string | Uint8Array | null>) => {
    const current = latest.current;
    if (!current || current.id !== id || current.files !== expectedFiles) return false;
    updateFiles(changes);
    return true;
  }, [updateFiles]);

  const rename = useCallback((input: string) => {
    const name = input.trim() || "My Widget";
    edit((current) => {
      const report = packageReport(current);
      if (!report.manifest) return { ...current, name };
      const manifest = { ...report.manifest, name: name.slice(0, 80) };
      return { ...current, name, files: { ...current.files, "widget.json": `${JSON.stringify(manifest, null, 2)}\n` } };
    });
  }, [edit]);

  const setFixtures = useCallback((fixtures: string) => edit((current) => ({ ...current, fixtures })), [edit]);

  const updateTutorial = useCallback((expected: Project, change: Pick<Project, "tutorial"> & { fixtures?: string }) => {
    const current = latest.current;
    if (!current || deletingProjects.current.has(current.id) || current.id !== expected.id || current.files !== expected.files || current.fixtures !== expected.fixtures || current.tutorial !== expected.tutorial) return false;
    return edit((draft) => ({ ...draft, ...change }), true);
  }, [edit]);

  return { ready, createdStarter, projects, project, path, saveState, openProject, addProject, removeProject, openFile: setPath, updateFiles, updateProjectFiles, rename, setFixtures, updateTutorial };
}
