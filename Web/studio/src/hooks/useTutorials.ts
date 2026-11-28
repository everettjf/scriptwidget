import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { loadTemplates } from "@/lib/templateCatalog.ts";
import { parseMocks } from "@/mockData.ts";
import { projectFromTemplate, type Project } from "@/project.ts";
import { simulateWidgetAction } from "@/simulateAction.ts";
import { activeLesson, nextTutorialStep, tutorialStepPassed } from "@/tutorialProgress.ts";
import { createTutorialProject, tutorials, tutorialScenario, type TutorialId, type TutorialStep } from "@/tutorials.ts";
import { previewIsCurrent } from "@/validationReport.ts";
import type { PreviewSettings, PreviewState } from "@/hooks/usePreview.ts";
import type { ProjectsModel } from "@/hooks/useProjects.ts";

const session = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;

function cloudFixtures(text: string, preset: "empty" | "saved"): string {
  const fixtures = parseMocks(text);
  fixtures.icloud = {
    connected: true,
    available: true,
    documents: preset === "empty" ? {} : {
      "todo.json": {
        value: { version: 1, items: { outline: { change: 1, done: true } } },
        revision: "tutorial-1",
        state: "cached",
        conflicts: [],
      },
    },
  };
  return JSON.stringify(fixtures, null, 2);
}

export function useTutorials(model: ProjectsModel, settings: PreviewSettings, preview: PreviewState, changeSettings: (value: Partial<PreviewSettings>) => void) {
  const { project, updateTutorial } = model;
  const progress = project?.tutorial;
  const lesson = activeLesson(progress);
  const step = nextTutorialStep(progress);
  const [catalogOpen, setCatalogOpen] = useState(false);
  const [pending, setPending] = useState<string | null>(null);
  const starting = useRef(false);
  const actionPending = useRef(false);
  const [actionError, setActionError] = useState<{ project: string; step: string; message: string } | null>(null);
  const live = useRef({ project, settings });
  live.current = { project, settings };
  const currentPreview = project && previewIsCurrent(project, settings, preview);
  const waitingForActionPreview = !!step?.expected.actionID && progress?.actionID === step.expected.actionID && !currentPreview;

  useEffect(() => {
    if (!project || !step || !progress || !tutorialStepPassed(project, progress, step, settings, preview, session)) return;
    updateTutorial(project, {
      tutorial: { ...progress, completed: [...progress.completed, { id: step.id, session }], actionID: undefined, scenarioID: undefined },
    });
  }, [project, progress, step, settings, preview, updateTutorial]);

  function latestDraft(id: TutorialId) {
    const current = project && activeLesson(project.tutorial)?.id === id ? project : null;
    return model.projects.reduce<Project | null>((latest, item) => {
      if (activeLesson(item.tutorial)?.id !== id || (latest && latest.updatedAt >= item.updatedAt)) return latest;
      return item;
    }, current);
  }

  const catalogProgress: Partial<Record<TutorialId, { completed: number; total: number }>> = {};
  for (const item of tutorials) {
    const draft = latestDraft(item.id);
    if (draft?.tutorial) catalogProgress[item.id] = { completed: draft.tutorial.completed.length, total: item.steps.length };
  }

  async function selectLesson(id: TutorialId, restart = false) {
    if (starting.current) return;
    const definition = tutorials.find(item => item.id === id);
    if (!definition) return;
    starting.current = true;
    setCatalogOpen(false);
    try {
      const existing = restart ? null : latestDraft(id);
      if (existing?.tutorial) {
        model.openProject(existing);
        if (!existing.tutorial.open) updateTutorial(existing, { tutorial: { ...existing.tutorial, open: true } });
        if (existing.id !== project?.id) changeSettings({ parameter: "", timelineDate: "" });
      } else {
        const draft = createTutorialProject(id);
        await model.addProject({ ...draft, tutorial: { lessonId: id, version: definition.version, completed: [], open: true } });
        changeSettings({ family: id === "event-countdown" ? "small" : "medium", parameter: "", timelineDate: "" });
      }
      requestAnimationFrame(() => document.getElementById("tutorial-heading")?.focus());
    } catch (error) {
      toast.error("Could not open the tutorial", { description: (error as Error).message });
    } finally { starting.current = false; }
  }

  function setGuideOpen(open: boolean) {
    if (project && progress && progress.open !== open) updateTutorial(project, { tutorial: { ...progress, open } });
  }

  async function runStep(currentStep: TutorialStep) {
    if (!project || !progress || !lesson || step !== currentStep || !step?.control || waitingForActionPreview) return;
    setActionError(null);
    const control = step.control;
    if (control.kind === "family") {
      changeSettings({ family: control.family });
      return;
    }
    if (control.kind === "scenario") {
      updateTutorial(project, { tutorial: { ...progress, scenarioID: control.scenarioID }, fixtures: tutorialScenario(lesson.id, control.scenarioID) });
      if (settings.timelineDate) changeSettings({ timelineDate: "" });
      return;
    }
    if (actionPending.current) return;
    actionPending.current = true;
    setPending(project.id);
    try {
      const result = await simulateWidgetAction(project, control.actionID, settings);
      if (live.current.project?.id !== project.id) return;
      if (live.current.settings.parameter !== settings.parameter || live.current.settings.appearance !== settings.appearance) {
        throw new Error("Preview settings changed while the action was running. Run the action again.");
      }
      const updated = updateTutorial(project, {
        tutorial: { ...progress, actionID: result.error ? undefined : control.actionID },
        ...(result.fixtures !== undefined && { fixtures: result.fixtures }),
      });
      if (!updated) throw new Error("The draft changed while the action was running. Run the action again.");
      if (result.error) throw new Error(result.error);
    } catch (error) {
      setActionError({ project: project.id, step: currentStep.id, message: (error as Error).message });
    } finally {
      actionPending.current = false;
      setPending(null);
    }
  }

  function editFile(file: string) {
    model.openFile(file);
    requestAnimationFrame(() => document.querySelector<HTMLElement>("#editor .cm-content")?.focus());
  }

  async function openCloudExample() {
    if (starting.current) return;
    starting.current = true;
    try {
      const template = (await loadTemplates()).find(item => item.id === "template/To-do List iCloud");
      if (!template) throw new Error("The iCloud example is missing from the template catalog.");
      if (live.current.project?.id !== project?.id) return;
      const draft = projectFromTemplate(template);
      await model.addProject({ ...draft, fixtures: cloudFixtures(draft.fixtures, "saved"), tutorialCloudExample: true });
      changeSettings({ family: "medium", parameter: "", timelineDate: "" });
      requestAnimationFrame(() => document.getElementById("tutorial-cloud-heading")?.focus());
    } catch (error) {
      toast.error("Could not open the iCloud example", { description: (error as Error).message });
    } finally { starting.current = false; }
  }

  const failedPreview = preview.output.kind === "unavailable" || (currentPreview && (preview.output.kind === "error" || preview.problems.some(problem => problem.severity === "error")));
  const currentActionError = actionError?.project === project?.id && actionError?.step === step?.id ? actionError?.message : undefined;
  const status = currentActionError ?? (failedPreview && step ? "Check the preview or Problems for the error. The guide will continue after a successful preview." : undefined);

  return {
    lesson, progress, catalogOpen, setCatalogOpen, catalogProgress, selectLesson, setGuideOpen, runStep,
    status, error: !!status, busy: (pending !== null && project?.id === pending) || waitingForActionPreview,
    editStep: () => editFile(step?.file ?? "main.jsx"), openCloudExample,
    skipReload: () => {
      if (!project || !progress || !step?.expected.reload || model.saveState !== "unavailable") return;
      updateTutorial(project, { tutorial: { ...progress, completed: [...progress.completed, { id: step.id, session, skipped: true }] } });
    },
    readCloudTutorial: () => editFile("README.md"),
    setCloudPreset: (preset: "empty" | "saved") => {
      if (!project?.tutorialCloudExample) return;
      // Replace only iCloud fixtures so other mock inputs survive preset changes.
      try { model.setFixtures(cloudFixtures(project.fixtures, preset)); }
      catch (error) { toast.error("Fix the full JSON in Mock Data first", { description: (error as Error).message }); }
    },
  };
}
