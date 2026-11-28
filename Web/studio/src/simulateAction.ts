import type { PreviewSettings } from "@/hooks/usePreview.ts";
import { parseMocks } from "@/mockData.ts";
import { executionFiles, packageReport, type Project } from "@/project.ts";
import { sandbox } from "@/runtime.ts";

export async function simulateWidgetAction(project: Project, actionID: string, settings: Pick<PreviewSettings, "appearance" | "parameter">) {
  const { manifest } = packageReport(project);
  const fixtures = parseMocks(project.fixtures);
  const result = await sandbox.execute({
    files: executionFiles(project.files), manifest, actionID, fixtures,
    environments: { "widget-size": "action", "widget-param": settings.parameter },
    preview: { appearance: settings.appearance },
  });
  return {
    error: result.error?.message,
    fixtures: result.mockState === undefined ? undefined : JSON.stringify({ ...fixtures, ...result.mockState }, null, 2),
    usesICloud: manifest?.permissions.includes("icloud") ?? false,
  };
}
