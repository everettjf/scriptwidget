import { resolveScreenshot } from "./locale";
import type { ProjectState } from "./types";

/** Only assets used by the deck being exported; inactive decks may be unfinished. */
export function exportAssetPaths(state: ProjectState): string[] {
  const paths = new Set<string>();
  const add = (path: string | undefined) => { if (path) paths.add(path); };
  for (const slide of state.slidesByDevice[state.device] || []) {
    if (state.device === "feature-graphic" || slide.layout === "feature-graphic") {
      add(state.appIcon);
      continue;
    }
    if (slide.layout !== "no-device" || slide.transforms?.device || slide.transforms?.deviceSecondary) {
      if (state.device === "iphone") add("/mockup.png");
      for (const locale of state.locales) {
        add(resolveScreenshot(slide.screenshot, locale));
        if (slide.layout === "two-devices" || slide.transforms?.deviceSecondary) {
          add(resolveScreenshot(slide.screenshotSecondary, locale));
        }
      }
    }
    for (const image of slide.imageElements || []) add(image.src);
  }
  return [...paths];
}
