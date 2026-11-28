import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, Check, Copy, CopyPlus, Search } from "lucide-react";
import type { Appearance, WidgetSize } from "../../../preview-engine/src/types.js";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { familyLabels, packageReport, previewFamilies, type Template } from "@/project.ts";
import { loadTemplates } from "@/lib/templateCatalog.ts";
import { renderTemplate, templateFiles } from "@/lib/templatePreview.ts";

const categoryLabels: Record<string, string> = {
  starter: "Starter", time: "Time", weather: "Weather", system: "System", health: "Health",
  finance: "Finance", productivity: "Productivity", fun: "Fun", gallery: "Gallery",
};
const categoryLabel = (category: string) => categoryLabels[category] ?? category.charAt(0).toUpperCase() + category.slice(1);

/// A live render of a template at one size, scaled to fit `maxWidth`.
/// Renders when it scrolls into view.
function LivePreview({ template, family, appearance, maxWidth, maxHeight, lazy = true }: { template: Template; family: WidgetSize; appearance: Appearance; maxWidth: number; maxHeight: number; lazy?: boolean }) {
  const host = useRef<HTMLDivElement>(null);
  const frame = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(!lazy);
  const [state, setState] = useState<{ width: number; height: number } | { error: string } | null>(null);

  useEffect(() => {
    if (visible || !frame.current) return;
    const observer = new IntersectionObserver((entries) => { if (entries.some((entry) => entry.isIntersecting)) setVisible(true); }, { rootMargin: "200px" });
    observer.observe(frame.current);
    return () => observer.disconnect();
  }, [visible]);

  useEffect(() => {
    if (!visible) return;
    let cancelled = false;
    setState(null);
    renderTemplate(template, family, { appearance }).then((result) => {
      if (cancelled || !host.current) return;
      if (result.kind === "error") { host.current.replaceChildren(); setState({ error: result.message }); return; }
      result.element.classList.add("rounded-[18px]", "overflow-hidden", "shadow-sm", "ring-1", "ring-black/5", "dark:ring-white/10");
      host.current.replaceChildren(result.element);
      setState({ width: result.width, height: result.height });
    });
    return () => { cancelled = true; };
  }, [visible, template, family, appearance]);

  const scale = state && "width" in state ? Math.min(1, maxWidth / state.width, maxHeight / state.height) : 1;
  return (
    <div ref={frame} className="flex items-center justify-center" style={{ height: state && "width" in state ? state.height * scale : maxHeight, width: "100%" }}>
      {state && "error" in state && <p className="px-3 text-center text-xs text-muted-foreground">Preview unavailable: {state.error}</p>}
      {!state && <div className="size-8 animate-pulse rounded-full bg-muted" aria-hidden="true" />}
      <div ref={host} aria-label={`${template.name} preview`} role="img"
        style={state && "width" in state ? { transform: `scale(${scale})`, transformOrigin: "center", width: state.width, height: state.height, flex: "none" } : { display: "none" }} />
    </div>
  );
}

function TemplateCard({ template, appearance, onOpen }: { template: Template; appearance: Appearance; onOpen(): void }) {
  return (
    <button type="button" onClick={onOpen}
      className="template-card group flex h-full w-full flex-col gap-2 rounded-xl border bg-sidebar p-3 text-left outline-none hover:border-primary/50 hover:bg-accent focus-visible:ring-[3px] focus-visible:ring-ring/50">
      <LivePreview template={template} family="small" appearance={appearance} maxWidth={150} maxHeight={150} />
      <span className="truncate font-semibold">{template.name}</span>
      <span className="text-[11px] text-primary">{template.source === "gallery" ? "Gallery" : categoryLabel(template.category)}</span>
      <span className="line-clamp-2 text-xs text-muted-foreground">{template.description}</span>
    </button>
  );
}

/// One template: a live preview at every size it supports, its files as
/// read-only source, and "Create a copy" to open it as a new local project.
function TemplateDetail({ template, appearance, onBack, onCopy }: { template: Template; appearance: Appearance; onBack(): void; onCopy(): void }) {
  const files = templateFiles(template);
  const families = useMemo(() => previewFamilies(packageReport({ files }).manifest, "iphone-393"), [files]);
  const [family, setFamily] = useState<WidgetSize>(families.includes("medium") ? "medium" : families[0] ?? "small");
  const paths = Object.keys(files).filter((path) => typeof files[path] === "string").sort((a, b) => (a === "main.jsx" ? -1 : b === "main.jsx" ? 1 : a.localeCompare(b)));
  const [path, setPath] = useState(paths[0] ?? "main.jsx");
  const [copied, setCopied] = useState(false);
  const source = typeof files[path] === "string" ? (files[path] as string) : "";

  const copySource = async () => {
    try { await navigator.clipboard.writeText(source); setCopied(true); setTimeout(() => setCopied(false), 1500); } catch { /* clipboard unavailable */ }
  };

  return (
    <div id="template-detail" className="flex min-h-0 flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="ghost" size="sm" onClick={onBack} aria-label="Back to all templates"><ArrowLeft /> All templates</Button>
        <span className="flex-1" />
        <Button id="template-copy" size="sm" onClick={onCopy}><CopyPlus /> Create a copy</Button>
      </div>
      <div className="grid min-h-0 gap-4 overflow-auto md:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
        <div className="flex min-w-0 flex-col gap-3">
          <div>
            <h3 className="text-lg font-semibold">{template.name}</h3>
            <p className="text-sm text-muted-foreground">{template.description}</p>
            {template.tags && template.tags.length > 0 && (
              <p className="mt-1.5 flex flex-wrap gap-1">{template.tags.map((tag) => <span key={tag} className="rounded-full border px-2 text-[11px] text-muted-foreground">{tag}</span>)}</p>
            )}
          </div>
          <div role="group" aria-label="Widget size" className="flex flex-wrap gap-1">
            {families.map((item) => (
              <button key={item} type="button" aria-pressed={item === family} onClick={() => setFamily(item)}
                className={cn("rounded-full border px-2.5 py-0.5 text-xs outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50", item === family ? "border-primary bg-primary text-primary-foreground" : "bg-card hover:bg-accent")}>
                {familyLabels[item]}
              </button>
            ))}
          </div>
          <div className="flex min-h-48 items-center justify-center rounded-xl bg-muted/50 p-4">
            <LivePreview template={template} family={family} appearance={appearance} maxWidth={360} maxHeight={380} lazy={false} />
          </div>
          <p className="text-xs text-muted-foreground">The copy is saved in this browser. Templates stay unchanged, so you can make as many copies as you like.</p>
        </div>
        <div className="flex min-w-0 flex-col gap-2">
          <div className="flex items-center gap-1">
            <div role="group" aria-label="Files" className="flex min-w-0 flex-1 flex-wrap gap-1">
              {paths.map((item) => (
                <button key={item} type="button" aria-pressed={item === path} onClick={() => setPath(item)}
                  className={cn("rounded-md px-2 py-0.5 font-mono text-xs outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50", item === path ? "bg-accent font-semibold" : "text-muted-foreground hover:bg-accent")}>
                  {item}
                </button>
              ))}
            </div>
            <Button variant="ghost" size="sm" onClick={copySource} aria-label={`Copy ${path}`}>{copied ? <Check /> : <Copy />}{copied ? "Copied" : "Copy"}</Button>
          </div>
          <pre id="template-source" className="max-h-[60vh] min-h-48 overflow-auto rounded-lg border bg-sidebar p-3 font-mono text-[12px] leading-relaxed whitespace-pre">{source}</pre>
        </div>
      </div>
    </div>
  );
}

export function TemplatesDialog({ open, onOpenChange, onChoose, appearance, initialQuery = "" }: { initialQuery?: string; open: boolean; appearance: Appearance; onOpenChange(open: boolean): void; onChoose(template: Template): void }) {
  const [templates, setTemplates] = useState<Template[] | null>(null);
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<string>("all");
  const [selected, setSelected] = useState<Template | null>(null);
  useEffect(() => {
    if (open) { setQuery(initialQuery); setCategory("all"); }
  }, [open, initialQuery]);
  useEffect(() => {
    if (open && !templates) loadTemplates().then(setTemplates, () => setTemplates([]));
    if (!open) setSelected(null);
  }, [open, templates]);

  const categories = useMemo(() => [...new Set((templates ?? []).map((template) => (template.source === "gallery" ? "gallery" : template.category)))].sort(), [templates]);
  const visible = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return (templates ?? []).filter((template) => {
      const group = template.source === "gallery" ? "gallery" : template.category;
      if (category === "featured" ? !template.featured : category !== "all" && group !== category) return false;
      return !needle || `${template.name} ${template.description} ${template.category} ${(template.tags ?? []).join(" ")}`.toLowerCase().includes(needle);
    }).sort((a, b) => Number(Boolean(b.featured)) - Number(Boolean(a.featured)) || a.name.localeCompare(b.name));
  }, [templates, query, category]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="flex max-h-[calc(100vh-3rem)] flex-col sm:max-w-5xl">
        <DialogHeader>
          <DialogTitle>Gallery</DialogTitle>
          <DialogDescription>Preview templates at each supported size, read their source, and create a copy. Previews use sample data for network requests and system services.</DialogDescription>
        </DialogHeader>
        {selected ? (
          <TemplateDetail template={selected} appearance={appearance} onBack={() => setSelected(null)} onCopy={() => onChoose(selected)} />
        ) : (
          <>
            <div className="flex flex-col gap-2">
              <div className="relative">
                <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
                <Input id="template-search" type="search" placeholder="Search templates" aria-label="Search templates" className="pl-8"
                  value={query} onChange={(event) => setQuery(event.target.value)} />
              </div>
              <div role="group" aria-label="Category" className="flex flex-wrap gap-1">
                {["all", "featured", ...categories].map((item) => (
                  <button key={item} type="button" aria-pressed={item === category} onClick={() => setCategory(item)}
                    className={cn("rounded-full border px-2.5 py-0.5 text-xs outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50", item === category ? "border-primary bg-primary text-primary-foreground" : "bg-card hover:bg-accent")}>
                    {item === "all" ? "All" : item === "featured" ? "Featured" : categoryLabel(item)}
                  </button>
                ))}
              </div>
            </div>
            <ul id="template-list" className="-mx-1 grid min-h-0 grid-cols-[repeat(auto-fill,minmax(176px,1fr))] gap-2.5 overflow-auto px-1 pb-1">
              {templates === null && <li className="text-sm text-muted-foreground">Loading templates…</li>}
              {templates !== null && visible.length === 0 && <li className="text-sm text-muted-foreground">No templates match. Try another word or category.</li>}
              {visible.map((template) => <li key={template.id}><TemplateCard template={template} appearance={appearance} onOpen={() => setSelected(template)} /></li>)}
            </ul>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
