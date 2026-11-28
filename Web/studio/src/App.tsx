import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { toast } from "sonner";
import { exportPackage, importPackage, newProjectFiles } from "../../preview-engine/src/package/index.js";
import type { WidgetSize } from "../../preview-engine/src/types.js";
import { ValidationDialog } from "@/components/ValidationDialog";
import { previewIsCurrent, validationReport } from "@/validationReport.ts";
import { EditorPane } from "@/components/EditorPane";
import { InstallDialog } from "@/components/InstallDialog";
import { NewFileDialog } from "@/components/NewFileDialog";
import { PreviewPane, type DetailTab } from "@/components/PreviewPane";
import { Sidebar } from "@/components/Sidebar";
import { TemplatesDialog } from "@/components/TemplatesDialog";
import { TopBar } from "@/components/TopBar";
import { TutorialCloudGuide, TutorialGuide, TutorialsDialog } from "@/components/TutorialGuide";
import { WallpaperDialog } from "@/components/WallpaperDialog";
import { isWallpaperTemplate } from "@/wallpaperConfiguration.ts";
import { useColorScheme } from "@/hooks/useColorScheme.ts";
import { useConfirm } from "@/hooks/useConfirm.tsx";
import { usePreview, type PreviewSettings } from "@/hooks/usePreview.ts";
import { useProjects } from "@/hooks/useProjects.ts";
import { useTutorials } from "@/hooks/useTutorials.ts";
import { downloadBytes } from "@/lib/download.ts";
import { createProject, packageReport, previewFamilies, projectFromTemplate, type Template } from "@/project.ts";
import { preferences } from "@/store.ts";

import { consumePreviewFragment, importPreviewFragment } from '@/previewHandoff.ts';

const initialPreviewFragment = consumePreviewFragment(window.location, window.history);
const maximumImageBytes = 8 * 1024 * 1024;

function initialSettings(colorScheme: "light" | "dark"): PreviewSettings {
  return {
    profile: preferences.read("profile", "iphone-393"),
    family: preferences.read<WidgetSize>("family", "medium"),
    appearance: preferences.read("appearance", colorScheme),
    renderingMode: "fullColor",
    parameter: "",
    timelineDate: "",
    reduceTransparency: window.matchMedia("(prefers-reduced-transparency: reduce)").matches,
    reduceMotion: window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  };
}

export function App() {
  const colorScheme = useColorScheme();
  const model = useProjects();
  const { project, path } = model;
  const previewLinkConsumed = useRef(false);
  const previewImportQueue = useRef(Promise.resolve());
  useEffect(() => {
    if (!model.ready) return;
    const enqueue = (fragment: string | null) => {
      if (!fragment) return;
      previewImportQueue.current = previewImportQueue.current.then(async () => {
        try {
          const result = await importPreviewFragment(fragment);
          await model.addProject(createProject(result.manifest.name, result.files));
          toast.success(`Loaded ${result.manifest.name} from your Agent`, { description: 'Saved as a separate project. Browser preview uses mock data.' });
        } catch (error) { toast.error('Could not load the preview link', { description: error instanceof Error ? error.message : 'Invalid widget package.' }); }
      });
    };
    if (!previewLinkConsumed.current) {
      previewLinkConsumed.current = true;
      enqueue(initialPreviewFragment);
    }
    const onHashChange = () => enqueue(consumePreviewFragment(window.location, window.history));
    onHashChange();
    window.addEventListener('hashchange', onHashChange);
    return () => window.removeEventListener('hashchange', onHashChange);
  }, [model.ready, model.addProject]);
  const [settings, setSettings] = useState(() => initialSettings(colorScheme));
  const [tab, setTab] = useState<DetailTab>("problems");
  const [templatesOpen, setTemplatesOpen] = useState(false);
  const [templateQuery, setTemplateQuery] = useState("");
  const [starterDismissed, setStarterDismissed] = useState(false);
  const [validationOpen, setValidationOpen] = useState(false);
  const [newFileOpen, setNewFileOpen] = useState(false);
  const [wallpaperProject, setWallpaperProject] = useState<string | null>(null);
  const [installedFile, setInstalledFile] = useState<string | null>(null);
  const [confirm, confirmDialog] = useConfirm();
  const importInput = useRef<HTMLInputElement>(null);
  const imageInput = useRef<HTMLInputElement>(null);

  const report = useMemo(() => (project ? packageReport(project) : null), [project]);
  const families = useMemo(() => previewFamilies(report?.manifest, settings.profile), [report, settings.profile]);
  // Keep the chosen size when the device or manifest supports it.
  const family: WidgetSize = families.includes(settings.family) ? settings.family : families.includes("medium") ? "medium" : families[0] ?? "medium";
  const effective = useMemo(() => ({ ...settings, family }), [settings, family]);
  const preview = usePreview(project, effective);

  const changeSettings = useCallback((change: Partial<PreviewSettings>) => {
    setSettings((current) => {
      const next = { ...current, ...change };
      for (const key of ["profile", "family", "appearance"] as const) if (key in change) preferences.write(key, next[key]);
      return next;
    });
  }, []);
  const tutorial = useTutorials(model, effective, preview, changeSettings);

  const onEdit = useCallback((file: string, text: string) => model.updateFiles({ [file]: text }), [model.updateFiles]);

  const exportCurrent = () => {
    if (!project) return null;
    const result = exportPackage(project.files);
    if (result.error !== undefined) {
      toast.error("Fix these problems before exporting", { description: result.error });
      setTab("problems");
      return null;
    }
    return result;
  };

  const install = async () => {
    const result = exportCurrent();
    if (!result) return;
    const file = new File([result.bytes as BlobPart], result.fileName, { type: "application/zip" });
    if (navigator.canShare?.({ files: [file] })) {
      try {
        await navigator.share({ files: [file], title: result.manifest.name });
        return;
      } catch (error) {
        if ((error as Error)?.name === "AbortError") return;
      }
    }
    downloadBytes(result.bytes, result.fileName);
    setInstalledFile(result.fileName);
  };

  const importFile = async (file: File) => {
    const result = await importPackage(new Uint8Array(await file.arrayBuffer()));
    if (result.error !== undefined) { toast.error(`${file.name} can't be imported`, { description: `${result.error} Export a .swt from ScriptWidget or Web Studio and try again.` }); return; }
    await model.addProject(createProject(result.manifest.name, result.files));
    toast.success(`Imported ${result.manifest.name}`);
  };

  const addImage = async (file: File) => {
    if (!project) return;
    if (file.size > maximumImageBytes) { toast.error("Images must be 8 MB or smaller, as in the ScriptWidget apps."); return; }
    const name = file.name.toLowerCase().replace(/[^a-z0-9._-]+/g, "-");
    const target = `image/${name}`;
    if (project.files[target] && !(await confirm({ title: `Replace ${target}?`, description: "The existing image is replaced in this project.", action: "Replace" }))) return;
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (!model.updateProjectFiles(project.id, project.files, { [target]: bytes })) {
      toast.error("The project changed while the image was being added. Add it again to the intended project.");
      return;
    }
    toast.success(`Added ${target}`, { description: `Insert it from Assets, or use <image name="${name}" /> in your widget.` });
  };

  // Dropping a .swt or .zip anywhere on the page imports it; images are
  // added to the open project.
  const [dragging, setDragging] = useState(false);
  const onDrop = (event: React.DragEvent) => {
    event.preventDefault();
    setDragging(false);
    const file = event.dataTransfer.files[0];
    if (!file) return;
    if (/\.(swt|zip)$/i.test(file.name)) void importFile(file);
    else if (/^image\/(png|jpeg|webp|gif)$/.test(file.type)) void addImage(file);
    else toast.error(`${file.name} isn't a widget package or image`, { description: "Drop a .swt or .zip package, or a PNG, JPEG, WebP, or GIF image." });
  };

  if (!project || !report) return <div className="grid h-full place-items-center text-sm text-muted-foreground">Loading projects…</div>;

  return (
    <div className="relative flex h-full flex-col max-[1100px]:h-auto"
      onDragOver={(event) => { if (event.dataTransfer.types.includes("Files")) { event.preventDefault(); setDragging(true); } }}
      onDragLeave={(event) => { if (event.currentTarget === event.target) setDragging(false); }}
      onDrop={onDrop}>
      {dragging && (
        <div id="drop-overlay" className="pointer-events-none absolute inset-0 z-40 grid place-items-center bg-primary/10 ring-4 ring-primary/40 ring-inset">
          <p className="rounded-lg bg-card px-4 py-2 text-sm font-medium shadow">Drop a .swt package to import it, or an image to add it</p>
        </div>
      )}
      <a href="#editor" className="sr-only focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:z-50 focus:rounded-md focus:bg-card focus:px-3 focus:py-1.5">Skip to editor</a>
      <TopBar
        projectName={project.name} projectID={project.id} onRename={model.rename}
        onNew={() => void model.addProject(createProject(`Widget ${model.projects.length + 1}`))}
        onTemplates={() => { setTemplateQuery(""); setTemplatesOpen(true); }}
        onImport={() => importInput.current?.click()}
        onExport={() => { const result = exportCurrent(); if (result) downloadBytes(result.bytes, result.fileName); }}
        onInstall={() => void install()}
        onValidate={() => setValidationOpen(true)}
        onLearn={() => tutorial.setCatalogOpen(true)}
      />
      {model.createdStarter && !initialPreviewFragment && !starterDismissed && model.projects.length === 1 && project.name === "My First Widget" && (
        <section id="starter-guide" aria-labelledby="starter-heading" className="flex flex-wrap items-center gap-3 border-b bg-sky-50 px-4 py-3 text-slate-900">
          <div className="min-w-48 flex-1">
            <h1 id="starter-heading" className="text-sm font-semibold">Start with something you can see.</h1>
            <p className="text-xs text-slate-600">Build your first widget with a short tutorial, or open a ready-made example.</p>
          </div>
          <div className="flex flex-wrap gap-2" role="group" aria-label="Starter examples">
            <Button size="sm" onClick={() => void tutorial.selectLesson("hello-world")}>Build your first widget</Button>
            {["Habit Heatmap", "Countdown", "Reading Goal"].map((name) => (
              <Button key={name} variant="outline" size="sm" onClick={() => { setTemplateQuery(name); setTemplatesOpen(true); }}>{name}</Button>
            ))}
            <Button variant="ghost" size="sm" onClick={() => setStarterDismissed(true)}>Keep editing</Button>
          </div>
        </section>
      )}
      <main className="grid min-h-0 flex-1 grid-cols-[220px_minmax(0,1fr)_minmax(360px,440px)] divide-x max-[1100px]:grid-cols-[200px_minmax(0,1fr)] max-[720px]:grid-cols-1 max-[720px]:divide-x-0">
        <Sidebar
          projects={model.projects} project={project} path={path} entry={report.manifest?.entry}
          onOpenProject={model.openProject}
          onDeleteProject={async (item) => {
            if (!(await confirm({ title: `Delete “${item.name}”?`, description: "The project is removed from this browser. Export it first if you want to keep it.", action: "Delete", destructive: true }))) return;
            try { await model.removeProject(item.id); }
            catch { toast.error("Project could not be deleted", { description: "The browser did not confirm deletion. Your project and edits were kept. Try again or export a backup." }); }
          }}
          onOpenFile={model.openFile}
          onDeleteFile={async (file) => {
            if (!(await confirm({ title: `Delete ${file}?`, description: "The file is removed from this project.", action: "Delete", destructive: true }))) return;
            model.updateFiles({ [file]: null });
            if (path === file) model.openFile(report.manifest?.entry ?? "widget.json");
          }}
          onAddFile={() => setNewFileOpen(true)}
          onAddImage={() => imageInput.current?.click()}
          onWallpaper={isWallpaperTemplate(project.files) ? () => setWallpaperProject(project.id) : undefined}
        />
        <EditorPane project={project} path={path} saveState={model.saveState} colorScheme={colorScheme} onChange={onEdit}
          onShowTutorial={tutorial.lesson ? () => { tutorial.setGuideOpen(true); document.getElementById("tutorial-heading")?.focus(); }
            : project.tutorialCloudExample ? () => document.getElementById("tutorial-cloud-heading")?.focus() : undefined} />
        <PreviewPane
          project={project}
          className="max-[1100px]:col-span-full max-[1100px]:border-t max-[720px]:-order-1 max-[720px]:border-t-0"
          settings={effective} families={families} onSettings={changeSettings} preview={preview} report={report}
          fixtures={project.fixtures} onFixtures={model.setFixtures} tab={tab} onTab={setTab}
          guide={tutorial.lesson && tutorial.progress ? (
            <TutorialGuide key={project.id} lesson={tutorial.lesson} completed={tutorial.progress.completed.map(item => item.id)}
              open={tutorial.progress.open} busy={tutorial.busy} status={tutorial.status} error={tutorial.error}
              onOpenChange={tutorial.setGuideOpen} onLearn={() => tutorial.setCatalogOpen(true)}
              onControl={(step) => void tutorial.runStep(step)} onEdit={tutorial.editStep} onInstall={() => void install()}
              reloadReady={model.saveState === "saved"} onReload={() => window.location.reload()}
              reloadSkipped={tutorial.progress.completed.some(item => item.skipped)}
              onSkipReload={model.saveState === "unavailable" ? tutorial.skipReload : undefined}
              onOpenCloudExample={tutorial.lesson.id === "interactive-todo" ? () => void tutorial.openCloudExample() : undefined} />
          ) : project.tutorialCloudExample ? (
            <TutorialCloudGuide onScenario={tutorial.setCloudPreset} onInstall={() => void install()} onReadSource={tutorial.readCloudTutorial} />
          ) : undefined}
        />
      </main>
      <TutorialsDialog open={tutorial.catalogOpen} onOpenChange={tutorial.setCatalogOpen} progress={tutorial.catalogProgress}
        onSelect={(id) => void tutorial.selectLesson(id)} onRestart={(id) => void tutorial.selectLesson(id, true)} />
      <ValidationDialog open={validationOpen} onOpenChange={setValidationOpen}
        ready={previewIsCurrent(project, effective, preview)}
        onImport={() => importInput.current?.click()}
        onCreate={source => void model.addProject(createProject("Pasted Widget", { ...newProjectFiles("Pasted Widget"), "main.jsx": source }))}
        onReport={() => void validationReport(project, effective, preview).then(value => downloadBytes(new TextEncoder().encode(JSON.stringify(value, null, 2)), "validation-report.json")).catch(error => toast.error((error as Error).message))}
      />
      <TemplatesDialog initialQuery={templateQuery} open={templatesOpen} onOpenChange={setTemplatesOpen}
        onChoose={(template: Template) => {
          setTemplatesOpen(false);
          setStarterDismissed(true);
          void model.addProject(projectFromTemplate(template)).then(() => toast.success(`Created a copy of ${template.name}`, { description: "It's saved in this browser. Export a .swt to keep it elsewhere." }));
        }} />
      <NewFileDialog open={newFileOpen} onOpenChange={setNewFileOpen} files={project.files}
        onCreate={(file) => { model.updateFiles({ [file]: /\.json$/i.test(file) ? "{}\n" : "" }); model.openFile(file); }} />
      <InstallDialog fileName={installedFile} onOpenChange={(open) => { if (!open) setInstalledFile(null); }} />
      {wallpaperProject === project.id && <WallpaperDialog key={project.id} project={project} onClose={() => setWallpaperProject(null)} onSave={(changes, expected) => {
        if (!model.updateProjectFiles(expected.id, expected.files, changes)) return false;
        toast.success("Saved wallpaper settings and crops", { description: "Export the widget package to use them on your device." });
        return true;
      }} />}
      {confirmDialog}
      <input id="import-input" ref={importInput} type="file" accept=".swt,.zip,application/zip" hidden
        onChange={(event) => { const file = event.target.files?.[0]; event.target.value = ""; if (file) void importFile(file); }} />
      <input id="image-input" ref={imageInput} type="file" accept="image/png,image/jpeg,image/webp,image/gif" hidden
        onChange={(event) => { const file = event.target.files?.[0]; event.target.value = ""; if (file) void addImage(file); }} />
    </div>
  );
}
