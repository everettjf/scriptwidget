import { useEffect, useState } from "react";
import { Download, LayoutGrid, Plus, Smartphone, Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import appIcon from "../../../../iOS/ScriptWidget/Assets/Assets.xcassets/AppIcon.appiconset/icon-64@2x.png";

interface TopBarProps {
  projectName: string;
  projectID: string | null;
  onRename(name: string): void;
  onNew(): void;
  onTemplates(): void;
  onImport(): void;
  onExport(): void;
  onInstall(): void;
  onValidate(): void;
}

export function TopBar({ projectName, projectID, onRename, onNew, onTemplates, onImport, onExport, onInstall, onValidate }: TopBarProps) {
  const [name, setName] = useState(projectName);
  // Show the stored name again when another project opens.
  useEffect(() => setName(projectName), [projectID, projectName]);
  const commit = () => { if (name.trim() !== projectName) onRename(name); };
  return (
    <header className="flex flex-wrap items-center gap-x-3 gap-y-2 border-b bg-card px-4 py-2">
      <a href="../" aria-label="ScriptWidget home" className="flex items-center gap-2 rounded-sm font-semibold whitespace-nowrap focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring">
        <img src={appIcon} width={24} height={24} alt="" className="size-6 shrink-0 rounded-md" />
        <span>ScriptWidget Studio</span>
      </a>
      <label className="min-w-32 flex-[1_1_10rem]">
        <span className="sr-only">Project name</span>
        <Input
          id="project-name" value={name} autoComplete="off" spellCheck={false}
          className="h-8 border-transparent bg-transparent font-semibold shadow-none hover:border-input focus-visible:border-ring dark:bg-transparent"
          onChange={(event) => setName(event.target.value)}
          onBlur={commit}
          onKeyDown={(event) => { if (event.key === "Enter") event.currentTarget.blur(); }}
        />
      </label>
      <nav className="flex flex-wrap gap-1.5" aria-label="Project actions">
        <Button id="open-validation" variant="outline" size="sm" onClick={onValidate}>Validate</Button>
        <Button id="new-project" variant="outline" size="sm" onClick={onNew}><Plus />New</Button>
        <Button id="open-templates" variant="outline" size="sm" onClick={onTemplates}><LayoutGrid />Gallery</Button>
        <Button id="import-package" variant="outline" size="sm" onClick={onImport}><Upload />Import</Button>
        <Button id="export-package" variant="outline" size="sm" onClick={onExport}><Download />Export .swt</Button>
        <Button id="install-package" size="sm" onClick={onInstall}><Smartphone />Install on iPhone</Button>
      </nav>
    </header>
  );
}
