import { useSyncExternalStore } from "react";

const query = () => globalThis.matchMedia?.("(prefers-color-scheme: dark)");

export function systemColorScheme(): "light" | "dark" {
  return query()?.matches ? "dark" : "light";
}

function subscribe(onChange: () => void): () => void {
  const media = query();
  media?.addEventListener("change", onChange);
  return () => media?.removeEventListener("change", onChange);
}

/// The system appearance, kept in sync with the OS setting.
export function useColorScheme(): "light" | "dark" {
  return useSyncExternalStore(subscribe, systemColorScheme, () => "light");
}
