import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { parseMocks } from "@/mockData.ts";
import { packageReport, type Project } from "@/project.ts";
import type { PreviewSettings } from "@/hooks/usePreview.ts";
import { simulateWidgetAction } from "@/simulateAction.ts";

export function ActionTestPanel({ project, settings, onFixtures }: { project: Project; settings: PreviewSettings; onFixtures(value: string): void }) {
  const actions = packageReport(project).manifest?.actions ?? [];
  const [selected, setSelected] = useState("");
  const [running, setRunning] = useState(false);
  const [message, setMessage] = useState("");
  const current = useRef({ project, settings }); current.current = { project, settings };
  const generation = useRef(0);
  useEffect(() => () => { generation.current += 1; }, [project.id]);
  const actionID = actions.some((action) => action.id === selected) ? selected : actions[0]?.id ?? "";
  const run = async () => {
    const captured = project, token = ++generation.current;
    setRunning(true); setMessage("");
    try {
      const result = await simulateWidgetAction(captured, actionID, settings);
      if (token !== generation.current) return;
      const live = current.current;
      if (live.project.id !== captured.id || live.project.files !== captured.files || live.project.fixtures !== captured.fixtures || live.settings.parameter !== settings.parameter || live.settings.appearance !== settings.appearance) {
        setMessage("The project changed. This simulation result was not applied."); return;
      }
      // Preserve uncertain/partial outcomes too, as real system writes can commit
      // before a later action error. These values remain preview-only.
      if (result.fixtures !== undefined) onFixtures(result.fixtures);
      setMessage(result.error ?? (result.usesICloud
        ? "Simulated action completed. iCloud writes last for this run. To preview a saved document, set it in iCloud JSON."
        : "Simulated action completed. Preview data has been updated."));
    } catch (error) { setMessage((error as Error).message); }
    finally { setRunning(false); }
  };
  const reset = () => {
    try {
      const fixtures = parseMocks(project.fixtures);
      delete fixtures.remindersState; delete fixtures.systemState; fixtures.storage = {};
      onFixtures(JSON.stringify(fixtures, null, 2));
      setMessage("Simulated action state reset. System reminders were not changed.");
    } catch (error) { setMessage((error as Error).message); }
  };
  return <div className="flex flex-col gap-2 border-b pb-3" aria-label="Simulate widget action">
    <p className="text-xs text-muted-foreground">Run a declared action against preview data. System reminders and other device data stay unchanged.</p>
    <div className="flex flex-wrap gap-2">
      <Select value={actionID} onValueChange={setSelected} disabled={running || actions.length === 0}>
        <SelectTrigger className="min-w-48" aria-label="Action to simulate"><SelectValue placeholder="No declared actions" /></SelectTrigger>
        <SelectContent>{actions.map((action) => <SelectItem key={action.id} value={action.id}>{action.title}</SelectItem>)}</SelectContent>
      </Select>
      <Button size="sm" disabled={running || !actionID} onClick={() => void run()}>{running ? "Running…" : "Run simulated action"}</Button>
      <Button size="sm" variant="outline" disabled={running} onClick={reset}>Reset simulated state</Button>
    </div>
    {message && <p role="status" className="whitespace-pre-wrap text-xs">{message}</p>}
  </div>;
}
