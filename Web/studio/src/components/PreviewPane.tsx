import { useEffect, useRef, type ReactNode } from "react";
import { deviceProfiles } from "../../../preview-engine/src/render/profiles.js";
import type { RenderingMode, WidgetSize } from "../../../preview-engine/src/types.js";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { timelinePreview, timelineInputValue } from "@/timelinePreview.ts";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { ActionTestPanel } from "@/components/ActionTestPanel";
import type { Project } from "@/project.ts";
import { MockDataPanel } from "@/components/MockDataPanel";
import { cn } from "@/lib/utils";
import { familyLabels, type PackageReport } from "@/project.ts";
import type { Message, PreviewAppearance, PreviewOutput, PreviewSettings, PreviewSettingsChange, PreviewState } from "@/hooks/usePreview.ts";

export type DetailTab = "problems" | "console" | "package" | "fixtures";

interface PreviewPaneProps {
  project: Project;
  settings: PreviewSettings;
  families: WidgetSize[];
  onSettings(change: PreviewSettingsChange): void;
  appearancePreference: PreviewAppearance;
  onAppearancePreference(appearance: PreviewAppearance): void;
  preview: PreviewState;
  report: PackageReport;
  fixtures: string;
  onFixtures(text: string): void;
  tab: DetailTab;
  onTab(tab: DetailTab): void;
  guide?: ReactNode;
  className?: string;
}

function Field({ id, label, children, className }: { id: string; label: string; children: ReactNode; className?: string }) {
  return (
    <div className={cn("flex flex-col gap-1", className)}>
      <Label htmlFor={id} className="text-xs font-normal text-muted-foreground">{label}</Label>
      {children}
    </div>
  );
}

function Choice<T extends string>({ id, value, options, onChange }: { id: string; value: T; options: Array<[T, string]>; onChange(value: T): void }) {
  return (
    <Select value={value} onValueChange={(next) => onChange(next as T)}>
      <SelectTrigger id={id} size="sm" className="min-w-28 bg-card"><SelectValue /></SelectTrigger>
      <SelectContent>
        {options.map(([option, label]) => <SelectItem key={option} value={option}>{label}</SelectItem>)}
      </SelectContent>
    </Select>
  );
}

const severityLabel = { error: "Error", warning: "Warning", info: "Note" } as const;
const severityColor = { error: "text-destructive", warning: "text-warning", info: "text-muted-foreground" } as const;

function Messages({ id, items, empty }: { id: string; items: Message[]; empty: string }) {
  return (
    <ul id={id} className="divide-y text-xs">
      {items.length === 0 && <li className="py-1.5 text-muted-foreground">{empty}</li>}
      {items.map((item, index) => (
        <li key={index} className={cn("py-1.5", item.severity)}>
          <strong className={severityColor[item.severity]}>{severityLabel[item.severity]}</strong> {item.text}
          {item.detail && <pre className="mt-1.5 font-mono text-xs break-words whitespace-pre-wrap text-foreground">{item.detail}</pre>}
        </li>
      ))}
    </ul>
  );
}

/// Shows the rendered widget element, or the runtime error.
function Stage({ output, guided }: { output: PreviewOutput; guided: boolean }) {
  const host = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const element = host.current;
    if (!element) return;
    if (output.kind === "widget") {
      output.element.classList.add("widget-frame", "flex-none", "rounded-[22px]", "shadow-[0_10px_30px_rgba(0,0,0,0.18)]", "ring-1", "ring-black/5", "dark:ring-white/12");
      element.replaceChildren(output.element);
    } else element.replaceChildren();
  }, [output]);
  return (
    <div id="stage" className={cn("grid shrink-0 place-items-center overflow-auto bg-stage px-3 py-6 max-[720px]:justify-items-start max-[720px]:p-4", guided ? "min-h-[220px]" : "min-h-[300px]")} aria-live="polite">
      <div ref={host} className={output.kind === "widget" ? "contents" : "hidden"} />
      {output.kind === "unavailable" && (
        <div id="runtime-unavailable" role="alert" className="max-w-sm rounded-xl border bg-card p-4 text-sm">
          <strong>The preview can't start</strong>
          <p className="mt-1.5 text-muted-foreground">{output.message}</p>
          <p className="mt-1.5 text-muted-foreground">You can keep editing, export the widget, and preview it in ScriptWidget on your device.</p>
        </div>
      )}
      {output.kind === "error" && (
        <div className="max-w-full rounded-xl border border-destructive bg-card p-3 text-destructive">
          <strong>{output.errorKind}</strong>
          <pre className="mt-1.5 font-mono text-xs break-words whitespace-pre-wrap text-foreground">{output.message}</pre>
        </div>
      )}
    </div>
  );
}

function statusText(output: PreviewOutput): string {
  switch (output.kind) {
    case "starting": return "Starting the preview runtime…";
    case "unavailable": return `The preview runtime could not start: ${output.message}`;
    case "error": return "Fix the error to see the preview.";
    case "widget": return `Web fast preview · ${output.milliseconds} ms · ${output.width}×${output.height} pt. Install it in ScriptWidget for the final look.`;
  }
}

function PackageSummary({ report }: { report: PackageReport }) {
  const manifest = report.manifest;
  if (!manifest) return <Messages id="package-issues" items={[{ severity: "error", text: report.issues[0]?.message ?? "widget.json is invalid." }]} empty="" />;
  const rows: Array<[string, string]> = [
    ["Identifier", manifest.id], ["Version", manifest.version], ["Entry", manifest.entry],
    ["Minimum runtime", manifest.minimumRuntimeVersion ?? "1.0"],
    ["Sizes", manifest.supportedFamilies.join(", ")],
    ["Permissions", manifest.permissions.length ? manifest.permissions.join(", ") : "None"],
    ["Network hosts", manifest.networkDomains.length ? manifest.networkDomains.join(", ") : "None"],
  ];
  return (
    <div id="package-summary" className="flex flex-col gap-2.5 text-xs">
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        {rows.map(([term, value]) => [
          <dt key={`${term}-term`} className="text-muted-foreground">{term}</dt>,
          <dd key={`${term}-value`} className="break-words">{value}</dd>,
        ])}
      </dl>
      <p className={report.valid ? "text-success" : "text-destructive"}>
        {report.valid ? "Ready to export: the manifest passes Package 2.0 validation." : "Fix the manifest errors in Problems before exporting."}
      </p>
      <p className="text-muted-foreground">Edit widget.json to change sizes, permissions, or network hosts. ScriptWidget asks the user to review permissions on import.</p>
    </div>
  );
}

export function PreviewPane({ project, settings, families, onSettings, appearancePreference, onAppearancePreference, preview, report, fixtures, onFixtures, tab, onTab, guide, className }: PreviewPaneProps) {
  let transitionDates: string[] = [];
  try { transitionDates = timelinePreview(report.manifest, settings.timelineDate).plan.entries.slice(1).map((entry) => entry.date); } catch { /* Package problems explain invalid schedules. */ }
  const errors = preview.problems.filter((item) => item.severity === "error").length;
  const controls = (
      <div className="flex flex-wrap gap-x-2.5 gap-y-2 border-b px-3 py-2.5">
        <Field id="profile" label="Device">
          <Choice id="profile" value={settings.profile} onChange={(profile) => onSettings({ profile })}
            options={Object.entries(deviceProfiles).map(([id, item]) => [id, item.label])} />
        </Field>
        <Field id="family" label="Size">
          <Choice<WidgetSize> id="family" value={settings.family} onChange={(family) => onSettings({ family })}
            options={families.map((family) => [family, familyLabels[family] ?? family])} />
        </Field>
        <Field id="appearance" label="Appearance">
          <Choice<PreviewAppearance> id="appearance" value={appearancePreference} onChange={onAppearancePreference}
            options={[["system", "System"], ["light", "Light"], ["dark", "Dark"]]} />
        </Field>
        <Field id="rendering-mode" label="Mode">
          <Choice<RenderingMode> id="rendering-mode" value={settings.renderingMode} onChange={(renderingMode) => onSettings({ renderingMode })}
            options={[["fullColor", "Full color"], ["accented", "Accented"], ["vibrant", "Vibrant"]]} />
        </Field>
        <div className="flex basis-full flex-wrap gap-3 text-xs text-muted-foreground" aria-label="Preview accessibility">
          <label className="flex items-center gap-1.5"><input id="reduce-transparency" type="checkbox" checked={settings.reduceTransparency} onChange={(event) => onSettings({reduceTransparency:event.target.checked})} />Reduce transparency</label>
          <label className="flex items-center gap-1.5"><input id="reduce-motion" type="checkbox" checked={settings.reduceMotion} onChange={(event) => onSettings({reduceMotion:event.target.checked})} />Reduce motion</label>
        </div>
        <Field id="timeline-date" label="Timeline date (your local time)" className="basis-full">
          <div className="flex gap-2">
            <Input id="timeline-date" type="datetime-local" className="h-8 min-w-0 flex-1 bg-card" value={timelineInputValue(settings.timelineDate)} onChange={(event) => onSettings({ timelineDate: event.target.value })} />
            <Button size="sm" variant="outline" onClick={() => onSettings({ timelineDate: "" })}>Now</Button>
          </div>
          <p className="text-xs text-muted-foreground">{settings.timelineDate ? "Fixed time previews a scheduled state using saved data. Writes and live requests are disabled." : "Current state. Set a date to preview scheduled changes."}</p>
          {transitionDates.length > 0 && <div className="flex flex-wrap gap-1">{transitionDates.map((date) => <Button key={date} size="xs" variant="outline" onClick={() => onSettings({ timelineDate: date })}>{new Date(date).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}</Button>)}</div>}
        </Field>
        <Field id="parameter" label="Parameter" className="basis-full">
          <Input id="parameter" className="h-8 bg-card" autoComplete="off" spellCheck={false} placeholder="widget-param"
            value={settings.parameter} onChange={(event) => onSettings({ parameter: event.target.value })} />
        </Field>
      </div>
  );
  return (
    <section className={cn("flex min-h-0 min-w-0 flex-col overflow-auto bg-sidebar", className)} aria-label="Preview">
      {guide}
      {!guide && controls}
      <Stage output={preview.output} guided={!!guide} />
      <p id="preview-status" className="border-b px-3 py-2 text-xs text-muted-foreground">{statusText(preview.output)}</p>
      {guide && <details className="shrink-0 border-b">
        <summary className="cursor-pointer px-3 py-2 text-xs font-medium focus-visible:outline-2 focus-visible:outline-ring focus-visible:outline-offset-[-2px]">Preview settings</summary>
        {controls}
      </details>}
      <Tabs value={tab} onValueChange={(next) => onTab(next as DetailTab)} className="flex-1 gap-0">
        <TabsList className="mx-3 mt-2 h-8">
          <TabsTrigger value="problems" className="text-xs">
            Problems{errors > 0 && <Badge variant="destructive" className="ml-1 h-4 px-1.5 text-[10px]">{errors}</Badge>}
          </TabsTrigger>
          <TabsTrigger value="console" className="text-xs">Console</TabsTrigger>
          <TabsTrigger value="package" className="text-xs">Package</TabsTrigger>
          <TabsTrigger value="fixtures" className="text-xs">Mock Data</TabsTrigger>
        </TabsList>
        {/* Panels stay mounted so their content is always in the page. */}
        <TabsContent forceMount value="problems" className="min-h-40 bg-card px-3 py-2.5 data-[state=inactive]:hidden">
          <Messages id="problems" items={preview.problems} empty="No problems found." />
        </TabsContent>
        <TabsContent forceMount value="console" className="min-h-40 bg-card px-3 py-2.5 data-[state=inactive]:hidden">
          <Messages id="console" items={preview.logs} empty="console.log output appears here." />
        </TabsContent>
        <TabsContent forceMount value="package" className="min-h-40 bg-card px-3 py-2.5 data-[state=inactive]:hidden">
          <PackageSummary report={report} />
        </TabsContent>
        <TabsContent forceMount value="fixtures" className="flex min-h-40 flex-col gap-2 bg-card px-3 py-2.5 data-[state=inactive]:hidden">
          <ActionTestPanel key={project.id} project={project} settings={settings} onFixtures={onFixtures} />
          <MockDataPanel fixtures={fixtures} onChange={onFixtures} />
        </TabsContent>
      </Tabs>
    </section>
  );
}
