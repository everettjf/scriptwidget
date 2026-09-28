import { DEVICE_LABEL, LAYOUT_LABEL } from "./constants";

const record = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);

/** Reject malformed generated/edited JSON before it can crash or overwrite a deck. */
export function projectValidationError(value: unknown): string | null {
  if (!record(value) || !record(value.slidesByDevice)) return "Project must contain a slidesByDevice object";
  for (const key of ["appName", "themeId", "locale", "appIcon"]) {
    if (value[key] !== undefined && typeof value[key] !== "string") return `${key} must be a string`;
  }
  if (value.device !== undefined && (typeof value.device !== "string" || !Object.hasOwn(DEVICE_LABEL, value.device))) {
    return "Unknown project device";
  }
  if (value.orientation !== undefined && value.orientation !== "portrait" && value.orientation !== "landscape") {
    return "Unknown project orientation";
  }
  if (value.locales !== undefined && (!Array.isArray(value.locales) ||
      value.locales.some(locale => typeof locale !== "string" || !/^[a-zA-Z0-9]+(?:[-_][a-zA-Z0-9]+)*$/.test(locale)) ||
      new Set(value.locales).size !== value.locales.length)) return "locales must be a list of unique locale codes";
  for (const [device, slides] of Object.entries(value.slidesByDevice)) {
    if (!Array.isArray(slides)) return `${device} deck must be an array`;
    const ids = new Set<string>();
    for (const slide of slides) {
      if (!record(slide) || typeof slide.id !== "string" || !slide.id.trim() || ids.has(slide.id)) {
        return `${device} screens must have unique non-empty ids`;
      }
      ids.add(slide.id);
      if (typeof slide.layout !== "string" || !Object.hasOwn(LAYOUT_LABEL, slide.layout)) return `${device}: unknown screen layout`;
      for (const key of ["screenshot", "screenshotSecondary"]) {
        if (slide[key] !== undefined && typeof slide[key] !== "string") return `${device}: ${key} must be a string`;
      }
    }
  }
  return null;
}
