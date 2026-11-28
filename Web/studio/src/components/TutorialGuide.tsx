import { useEffect, useRef } from "react";
import { ArrowRight, BookOpen, CalendarDays, Check, ChevronDown, ChevronUp, CloudSun, Code, ListChecks, Timer } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { tutorials, type TutorialId, type TutorialLesson, type TutorialStep } from "@/tutorials.ts";

const lessonIcons = {
  "hello-world": Code,
  "event-countdown": Timer,
  "interactive-todo": ListChecks,
  "weather-forecast": CloudSun,
  "calendar-agenda": CalendarDays,
} satisfies Record<TutorialId, typeof Code>;

interface TutorialsDialogProps {
  open: boolean;
  onOpenChange(open: boolean): void;
  progress: Partial<Record<TutorialId, { completed: number; total: number }>>;
  onSelect(id: TutorialId): void;
  onRestart?(id: TutorialId): void;
}

export function TutorialsDialog({ open, onOpenChange, progress, onSelect, onRestart }: TutorialsDialogProps) {
  const opener = useRef<HTMLElement | null>(null);
  const selected = useRef<TutorialId | null>(null);
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent id="tutorials-dialog" className="max-h-[90dvh] overflow-y-auto p-4 sm:max-w-2xl sm:p-6"
        onOpenAutoFocus={() => {
          selected.current = null;
          const active = document.activeElement;
          opener.current = active instanceof HTMLElement && active !== document.body ? active : null;
        }}
        onCloseAutoFocus={(event) => {
          event.preventDefault();
          if (selected.current) {
            const guide = document.getElementById("tutorial-guide");
            if (guide?.dataset.lessonId === selected.current) document.getElementById("tutorial-heading")?.focus();
            return;
          }
          const target = opener.current?.isConnected ? opener.current : document.getElementById("open-tutorials");
          target?.focus();
        }}>
        <DialogHeader className="pr-8 text-left">
          <DialogTitle>Learn Web Studio</DialogTitle>
          <DialogDescription>Build a widget in each lesson. Start anywhere and come back to your draft when you’re ready.</DialogDescription>
        </DialogHeader>
        <ol className="grid gap-2">
          {tutorials.map((lesson) => {
            const Icon = lessonIcons[lesson.id];
            const saved = progress[lesson.id];
            const finished = !!saved && saved.completed === saved.total;
            const label = finished ? "Open" : saved ? "Resume" : "Start";
            return (
              <li key={lesson.id} className="flex min-w-0 flex-wrap items-center gap-1 rounded-lg border bg-card hover:border-primary/50 focus-within:border-primary/50">
                <button type="button" data-tutorial-id={lesson.id} aria-label={`${label} ${lesson.title}`} aria-describedby={`tutorial-description-${lesson.id} tutorial-progress-${lesson.id}`} onClick={() => { selected.current = lesson.id; onSelect(lesson.id); }}
                  className="flex min-w-0 flex-[1_1_15rem] items-center gap-3 rounded-lg px-3 py-2.5 text-left outline-none hover:bg-accent/40 focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset">
                  <span className="grid size-9 shrink-0 place-items-center rounded-md bg-accent text-primary" aria-hidden="true">
                    {finished ? <Check className="size-4" /> : <Icon className="size-4" />}
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="block text-sm font-semibold">{lesson.title}</span>
                    <span id={`tutorial-description-${lesson.id}`} className="block text-xs leading-relaxed text-muted-foreground">{lesson.description}</span>
                    <span id={`tutorial-progress-${lesson.id}`} className="mt-0.5 block text-xs text-muted-foreground">
                      {finished ? "Completed" : saved ? `${saved.completed}/${saved.total} steps complete` : lesson.duration}
                    </span>
                  </span>
                  <span className="flex shrink-0 items-center gap-1 text-xs font-medium" aria-hidden="true">
                    <span className="hidden sm:inline">{label}</span>
                    <ArrowRight className="size-4" />
                  </span>
                </button>
                {saved && onRestart && (
                  <Button type="button" size="sm" variant="ghost" data-tutorial-restart={lesson.id} aria-label={`Start a new copy of ${lesson.title}`} className="mr-2 ml-auto" onClick={() => { selected.current = lesson.id; onRestart(lesson.id); }}>New copy</Button>
                )}
              </li>
            );
          })}
        </ol>
      </DialogContent>
    </Dialog>
  );
}

interface TutorialGuideProps {
  lesson: TutorialLesson;
  completed: readonly string[];
  open: boolean;
  busy: boolean;
  status?: string;
  error?: boolean;
  onOpenChange(open: boolean): void;
  onLearn(): void;
  onControl(step: TutorialStep): void;
  onEdit(): void;
  onInstall(): void;
  onReload(): void;
  reloadReady: boolean;
  reloadSkipped: boolean;
  onSkipReload?(): void;
  onOpenCloudExample?(): void;
}

export function TutorialGuide({ lesson, completed, open, busy, status, error, onOpenChange, onLearn, onControl, onEdit, onInstall, onReload, reloadReady, reloadSkipped, onSkipReload, onOpenCloudExample }: TutorialGuideProps) {
  const position = lesson.steps.findIndex((step) => !completed.includes(step.id));
  const step = lesson.steps[position];
  const total = lesson.steps.length;
  const count = lesson.steps.filter((item) => completed.includes(item.id)).length;
  const heading = useRef<HTMLHeadingElement>(null);
  const activatedStep = useRef<string>(null);
  useEffect(() => {
    if (activatedStep.current === null || activatedStep.current === step?.id) return;
    activatedStep.current = null;
    // Keep keyboard navigation in the guide when its action advances the lesson.
    if (open && document.activeElement === document.body) heading.current?.focus({ preventScroll: true });
  }, [open, step?.id]);
  return (
    <section id="tutorial-guide" aria-labelledby="tutorial-heading" data-lesson-id={lesson.id} data-step-id={step?.id} data-completed-count={count}
      className="min-w-0 shrink-0 border-b border-l-2 border-l-primary bg-card px-3 py-3 sm:px-4">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
        <BookOpen className="size-4 shrink-0 text-primary" aria-hidden="true" />
        <h2 id="tutorial-heading" tabIndex={-1} className="min-w-0 flex-1 text-sm font-semibold">{lesson.title}</h2>
        {(lesson.id === "weather-forecast" || lesson.id === "calendar-agenda") && <span className="rounded-full bg-accent px-2 py-0.5 text-xs text-accent-foreground">Sample data</span>}
        <Button size="xs" variant="ghost" aria-expanded={open} aria-controls="tutorial-guide-content" onClick={() => onOpenChange(!open)}>
          {open ? <ChevronUp /> : <ChevronDown />}
          {open ? "Hide guide" : "Show guide"}
        </Button>
      </div>
      <div id="tutorial-guide-content" hidden={!open}>
        <div className="mt-2 flex items-center gap-2">
          <div role="progressbar" aria-label="Lesson progress" aria-valuemin={0} aria-valuemax={total} aria-valuenow={count} className="flex max-w-24 flex-1 gap-1">
            {lesson.steps.map((item) => <span key={item.id} className={completed.includes(item.id) ? "h-1 flex-1 rounded-full bg-primary" : "h-1 flex-1 rounded-full bg-muted"} />)}
          </div>
          <span className="text-xs text-muted-foreground">{count}/{total} complete</span>
        </div>
        <p className="sr-only" role="status">{step ? `Step ${position + 1} of ${total}. ${step.title}` : "Lesson complete."}</p>
        {step ? (
          <div className="mt-2 space-y-1.5">
            <h3 ref={heading} tabIndex={-1} className="text-sm font-semibold">{step.title}</h3>
            <p className="text-xs leading-relaxed">{step.expected.reload && onSkipReload
              ? "Browser storage is unavailable. Reloading would lose this draft. You can finish the button exercise in this tab."
              : step.instruction}</p>
            {step.code && <pre className="overflow-x-auto rounded-md bg-muted p-2 text-xs"><code>{step.code}</code></pre>}
            {step.hint && !(step.expected.reload && onSkipReload) && (
              <details key={step.id} className="text-xs">
                <summary className="w-fit cursor-pointer rounded-sm text-muted-foreground focus-visible:outline-2 focus-visible:outline-offset-2">Show hint</summary>
                <p className="mt-1 leading-relaxed text-muted-foreground">{step.hint}</p>
              </details>
            )}
            <div className="flex flex-wrap items-center gap-1.5 pt-1">
              {step.file && <Button data-testid="tutorial-edit" size="sm" onClick={onEdit}>Open {step.file}</Button>}
              {step.control && <Button data-testid="tutorial-step-action" variant={step.file ? "outline" : "default"} size="sm" aria-disabled={busy} className="aria-disabled:opacity-50" onClick={(event) => {
                if (busy) return;
                if (document.activeElement === event.currentTarget) activatedStep.current = step.id;
                onControl(step);
              }}>{step.control.label}</Button>}
              {step.expected.reload && (onSkipReload
                ? <Button size="sm" onClick={(event) => {
                  if (document.activeElement === event.currentTarget) activatedStep.current = step.id;
                  onSkipReload();
                }}>Skip reload check</Button>
                : <Button size="sm" disabled={!reloadReady} onClick={onReload}>Reload Studio</Button>)}
              <Button size="sm" variant="ghost" onClick={onLearn}>All tutorials</Button>
            </div>
          </div>
        ) : (
          <div className="mt-2 space-y-1.5">
            <h3 ref={heading} tabIndex={-1} className="flex items-center gap-1.5 text-sm font-semibold"><Check className="size-4 text-success" aria-hidden="true" />Lesson complete</h3>
            <p className="text-xs leading-relaxed">{lesson.takeaway}</p>
            {reloadSkipped && <p className="text-xs leading-relaxed text-muted-foreground">The reload check was skipped because browser storage was unavailable.</p>}
            {lesson.deviceNote && <p className="text-xs leading-relaxed text-muted-foreground">{lesson.deviceNote}</p>}
            <div className="flex flex-wrap items-center gap-1.5 pt-1">
              <Button size="sm" onClick={onInstall}>Install on device</Button>
              {onOpenCloudExample && <Button variant="outline" size="sm" onClick={onOpenCloudExample}>Try the iCloud version</Button>}
              <Button size="sm" variant="ghost" onClick={onLearn}>All tutorials</Button>
            </div>
          </div>
        )}
        <p id="tutorial-status" role={error ? "alert" : "status"} className={status ? `mt-2 text-xs ${error ? "text-destructive" : "text-muted-foreground"}` : "sr-only"}>{status}</p>
      </div>
    </section>
  );
}

interface TutorialCloudGuideProps {
  onScenario(value: "empty" | "saved"): void;
  onInstall(): void;
  onReadSource(): void;
}

export function TutorialCloudGuide({ onScenario, onInstall, onReadSource }: TutorialCloudGuideProps) {
  return (
    <section id="tutorial-cloud-guide" aria-labelledby="tutorial-cloud-heading" className="min-w-0 shrink-0 space-y-2 border-b border-l-2 border-l-primary bg-card px-3 py-3 sm:px-4">
      <div className="flex items-center gap-2">
        <BookOpen className="size-4 shrink-0 text-primary" aria-hidden="true" />
        <h2 id="tutorial-cloud-heading" tabIndex={-1} className="text-sm font-semibold">Try an iCloud to-do list</h2>
        <span className="ml-auto rounded-full bg-accent px-2 py-0.5 text-xs text-accent-foreground">Simulated iCloud</span>
      </div>
      <p className="text-xs leading-relaxed">Compare an empty store with a sample saved list. In Mock Data, run a declared action to see how it writes. Simulated iCloud writes last for that run.</p>
      <div className="flex flex-wrap gap-1.5">
        <Button size="sm" variant="outline" onClick={() => onScenario("empty")}>Empty store</Button>
        <Button size="sm" variant="outline" onClick={() => onScenario("saved")}>Saved list</Button>
        <Button size="sm" variant="ghost" onClick={onReadSource}>Read the tutorial</Button>
      </div>
      <p className="text-xs leading-relaxed text-muted-foreground">To try real sync, import this package into ScriptWidget on two Apple devices. Connect the same store ID using the same Apple Account.</p>
      <Button size="sm" onClick={onInstall}>Install on device</Button>
    </section>
  );
}
