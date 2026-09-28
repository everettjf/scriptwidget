"use client";
import * as React from "react";
import { toast } from "sonner";
import { cleanFontName } from "@/lib/clean-imported-font";
import type { ImportedFont } from "@/lib/types";

export type FontImporterHandle = { open: () => void };

type Props = {
  onImported: (font: ImportedFont) => void;
  onUploadingChange?: (uploading: boolean) => void;
};

const MAX_FONT_BYTES = 16 * 1024 * 1024;

async function fileToBase64(file: File): Promise<string> {
  const dataUrl = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onloadend = () => resolve(reader.result as string);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
  return dataUrl.slice(dataUrl.indexOf(",") + 1);
}

// Hidden file input behind the toolbar's "Import font…" menu item. The server
// validates the file by its magic bytes and stores it under
// public/fonts/imported/<hash>.<ext>.
export const FontImporter = React.forwardRef<FontImporterHandle, Props>(function FontImporter(
  { onImported, onUploadingChange },
  ref,
) {
  const inputRef = React.useRef<HTMLInputElement>(null);
  React.useImperativeHandle(ref, () => ({ open: () => inputRef.current?.click() }), []);

  async function importFont(file: File) {
    onUploadingChange?.(true);
    try {
      if (file.size > MAX_FONT_BYTES) throw new Error("Font file is too large (16MB maximum).");
      const response = await fetch("/api/upload-font", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ data: await fileToBase64(file) }),
      });
      const data = (await response.json().catch(() => ({ ok: false }))) as {
        ok: boolean;
        error?: string;
        font?: ImportedFont;
      };
      if (!data.ok || !data.font) throw new Error(data.error || "Could not import that font.");
      const name = cleanFontName(file.name.replace(/\.[^.]+$/, ""));
      onImported({ ...data.font, ...(name ? { name } : {}) });
      toast.success(`Imported ${name ?? "font"}`);
    } catch (caught) {
      toast.error("Font import failed", {
        description: caught instanceof Error ? caught.message : "Could not import that font.",
      });
    } finally {
      onUploadingChange?.(false);
    }
  }

  return (
    <input
      ref={inputRef}
      type="file"
      accept=".woff2,.woff,.ttf,.otf,font/woff2,font/woff,font/ttf,font/otf"
      className="sr-only"
      tabIndex={-1}
      aria-hidden
      onChange={(event) => {
        const file = event.target.files?.[0];
        if (file) void importFont(file);
        event.target.value = "";
      }}
    />
  );
});
