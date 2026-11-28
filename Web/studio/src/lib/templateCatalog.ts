import type { Template } from "@/project.ts";

let catalog: Promise<Template[]> | undefined;

export function loadTemplates(): Promise<Template[]> {
  catalog ??= fetch(new URL("./templates.json", document.baseURI))
    .then(async (response) => {
      if (!response.ok) throw new Error("The template catalog could not be downloaded.");
      const result: { templates: Template[] } = await response.json();
      return result.templates;
    })
    .catch((error: unknown) => { catalog = undefined; throw error; });
  return catalog;
}
