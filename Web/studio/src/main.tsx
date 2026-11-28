import { StrictMode, useLayoutEffect } from "react";
import { createRoot } from "react-dom/client";
import { Toaster } from "sonner";
import { App } from "@/App.tsx";
import { TooltipProvider } from "@/components/ui/tooltip";
import { systemColorScheme, useColorScheme } from "@/hooks/useColorScheme.ts";
import "./index.css";

function applyColorScheme(colorScheme: "light" | "dark") {
  document.documentElement.classList.toggle("dark", colorScheme === "dark");
  document.documentElement.style.colorScheme = colorScheme;
}

/// Follows the system appearance with shadcn's `dark` class.
function Root() {
  const colorScheme = useColorScheme();
  useLayoutEffect(() => applyColorScheme(colorScheme), [colorScheme]);
  return (
    <TooltipProvider delayDuration={400}>
      <App colorScheme={colorScheme} />
      <Toaster theme={colorScheme} position="bottom-center" richColors closeButton />
    </TooltipProvider>
  );
}

// The widget renderer measures text during layout, so the fallback face must
// be ready before the first preview.
applyColorScheme(systemColorScheme());
try { await document.fonts.load('17px "ScriptWidget Inter"'); } catch { /* the system fallback still renders */ }

createRoot(document.getElementById("root")!).render(<StrictMode><Root /></StrictMode>);
