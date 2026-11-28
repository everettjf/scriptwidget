import type { PreviewSettings, PreviewState } from "./hooks/usePreview.ts";
import type { Project } from "./project.ts";
import { tutorials, tutorialSourceChanged, type TutorialId, type TutorialStep } from "./tutorials.ts";
import { previewIsCurrent } from "./validationReport.ts";

export interface TutorialProgress {
  lessonId: TutorialId;
  version: number;
  open: boolean;
  completed: Array<{ id: string; session: string; skipped?: true }>;
  scenarioID?: string;
  actionID?: string;
}

export function activeLesson(progress: TutorialProgress | undefined) {
  return tutorials.find(lesson => lesson.id === progress?.lessonId && lesson.version === progress.version);
}

export function nextTutorialStep(progress: TutorialProgress | undefined) {
  return activeLesson(progress)?.steps.find(step => !progress?.completed.some(item => item.id === step.id));
}

function hasWidgetAction(element: HTMLElement, actionID: string): boolean {
  const targets = [element, ...element.querySelectorAll<HTMLElement>("[data-sw-interaction]")];
  return targets.some(target => {
    const value = target.dataset.swInteraction;
    if (value === undefined) return false;
    const interaction = JSON.parse(value);
    return interaction.type === "button" && interaction.actionID === actionID;
  });
}

export function tutorialStepPassed(project: Project, progress: TutorialProgress, step: TutorialStep, settings: PreviewSettings, preview: PreviewState, session: string): boolean {
  if (preview.output.kind !== "widget" || !previewIsCurrent(project, settings, preview) || preview.problems.some(problem => problem.severity === "error")) return false;
  const expected = step.expected;
  if (expected.family && settings.family !== expected.family) return false;
  if (expected.scenarioID && progress.scenarioID !== expected.scenarioID) return false;
  if (expected.actionID && progress.actionID !== expected.actionID) return false;
  if (expected.reload && (!progress.completed.length || progress.completed.at(-1)?.session === session)) return false;
  if (expected.changedSource && !tutorialSourceChanged(progress.lessonId, project)) return false;
  if (expected.boundAction && !hasWidgetAction(preview.output.element, expected.boundAction)) return false;
  const glance = (value: string) => value.toLowerCase().replace(/\s+/g, " ").trim();
  return glance(preview.output.element.textContent ?? "").includes(glance(expected.text));
}
