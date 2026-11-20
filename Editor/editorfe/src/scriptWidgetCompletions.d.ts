import type { Completion, CompletionContext, CompletionResult } from "@codemirror/autocomplete";

export const scriptWidgetAPI: { components: Record<string, unknown>; [key: string]: unknown };
export const scriptWidgetCompletionOptions: Completion[];
export function scriptWidgetCompletions(context: CompletionContext): CompletionResult | null;

/** Hands over CodeMirror's `snippet`, so that accepting a completion places the cursor instead of writing the marks. */
export function useSnippets(snippet: ((template: string) => unknown) | null): void;
