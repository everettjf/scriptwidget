import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { parseMocks } from "@/mockData.ts";
import { executionFiles, packageReport, type Project } from "@/project.ts";
import { sandbox } from "@/runtime.ts";

export function ActionTestPanel({ project, onFixtures }: { project: Project; onFixtures(value: string): void }) {
  const actions = packageReport(project).manifest?.actions ?? [];
  const [selected, setSelected] = useState("");
  const [running, setRunning] = useState(false);
  const [message, setMessage] = useState("");
  const current = useRef(project); current.current = project;
  const generation = useRef(0);
  useEffect(() => () => { generation.current += 1; }, [project.id]);
  const actionID = actions.some((action) => action.id === selected) ? selected : actions[0]?.id ?? "";
  const run = async () => {
    const captured = project, token = ++generation.current;
    setRunning(true); setMessage("");
    try {
      const result = await sandbox.execute({ files: executionFiles(captured.files), manifest: packageReport(captured).manifest,
        fixtures: parseMocks(captured.fixtures), actionID, environments: { "widget-size": "action" } });
      if (token !== generation.current) return;
      if (current.current.id !== captured.id || current.current.files !== captured.files || current.current.fixtures !== captured.fixtures) {
        setMessage("The project changed. This simulation result was not applied."); return;
      }
      // Preserve uncertain/partial outcomes too, as real system writes can commit
      // before a later action error. These values remain preview-only.
      if (result.mockState) onFixtures(JSON.stringify({ ...parseMocks(captured.fixtures), ...result.mockState }, null, 2));
      setMessage(result.error ? result.error.message : "Simulated action completed. Preview data has been updated.");
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
