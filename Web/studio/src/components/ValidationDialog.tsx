import { useState } from "react";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";

interface Props {
  open: boolean;
  onOpenChange(open: boolean): void;
  onCreate(source: string): void;
  onImport(): void;
  onReport(): void;
  ready: boolean;
}
export function ValidationDialog({ open, onOpenChange, onCreate, onImport, onReport, ready }: Props) {
  const [source, setSource] = useState("");
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90dvh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Validate your widget</DialogTitle>
          <DialogDescription>Paste JSX or open a .swt package. Code runs in this browser with mock data. The preview is an approximation; Mac native validation is available through the CLI.</DialogDescription>
        </DialogHeader>
        <label className="grid gap-2 text-sm" htmlFor="validation-source">JSX code
          <textarea id="validation-source" rows={8} className="w-full rounded-md border bg-background p-3 font-mono text-xs placeholder:text-muted-foreground" spellCheck={false} value={source} onChange={event => setSource(event.target.value)} placeholder="$render(<text>Hello</text>);" />
        </label>
        <div className="flex flex-wrap gap-2">
          <Button id="validate-pasted-code" disabled={!source.trim()} onClick={() => { onCreate(source); setSource(""); onOpenChange(false); }}>Preview a new copy</Button>
          <Button variant="outline" onClick={() => { onOpenChange(false); onImport(); }}>Open .swt package</Button>
          <Button id="download-validation-report" variant="outline" disabled={!ready} onClick={onReport}>Download current report</Button>
        </div>
        <p className="text-xs text-muted-foreground">Pasting creates a new project and preserves your current files. Include widget.json and resources when checking a complete package. Reports contain diagnostics and mock results; review them before sharing with your agent.</p>
        <div className="grid gap-2 border-t pt-3 text-sm">
          <p>Create with your Agent using scriptwidget-creator:</p>
          <code className="overflow-x-auto rounded bg-muted p-2 text-xs">brew install everettjf/tap/scriptwidget-cli</code>
          <code className="overflow-x-auto rounded bg-muted p-2 text-xs">scriptwidget preview ./MyWidget</code>
          <a className="underline" href="https://github.com/everettjf/scriptwidget/releases/download/cli-v0.2.0/scriptwidget-creator-0.2.0.zip">Download scriptwidget-creator</a>
        </div>
      </DialogContent>
    </Dialog>
  );
}
