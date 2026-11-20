export interface HostProperty {
  type: string;
  documentation?: string;
  required?: boolean;
  values?: string[];
}

export interface HostComponent {
  documentation: string;
  children: boolean;
  properties: Record<string, HostProperty>;
}

export function readHostAPI(value: unknown): { components: Record<string, HostComponent>; colors: string[] };
export function editorAPI(): {
  api: { components: Record<string, unknown>; globalProperties: Record<string, unknown>; [key: string]: unknown };
  colors: string[];
  extended: boolean;
};
