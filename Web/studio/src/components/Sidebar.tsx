import { FileCode2, FileJson, Image as ImageIcon, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { IconButton } from "@/components/IconButton";
import { cn } from "@/lib/utils";
import { sortedPaths, type Project } from "@/project.ts";

interface SidebarProps {
  projects: Project[];
  project: Project;
  path: string;
  entry: string | undefined;
  onOpenProject(project: Project): void;
  onDeleteProject(project: Project): void;
  onOpenFile(path: string): void;
  onDeleteFile(path: string): void;
  onAddFile(): void;
  onAddImage(): void;
  onWallpaper?: () => void;
}

function SectionTitle({ children }: { children: string }) {
  return <h2 className="text-[11px] font-medium tracking-wider text-muted-foreground uppercase">{children}</h2>;
}

function Row({ current, label, icon, onOpen, onDelete, deleteLabel }: {
  current: boolean; label: string; icon?: React.ReactNode; onOpen(): void; onDelete?: () => void; deleteLabel: string;
}) {
  return (
    <li className="flex items-center gap-0.5">
      <button
        type="button" aria-current={current ? "true" : "false"} onClick={onOpen}
        className={cn(
          "flex min-w-0 flex-1 items-center gap-2 rounded-md px-2 py-1.5 text-left outline-none hover:bg-accent focus-visible:ring-[3px] focus-visible:ring-ring/50",
          current && "bg-primary/12 font-semibold hover:bg-primary/16",
        )}
      >
        {icon}
        <span className="truncate">{label}</span>
      </button>
      {onDelete && (
        <IconButton label={deleteLabel} className="size-7 text-muted-foreground" onClick={onDelete}>
          <Trash2 className="size-3.5" />
        </IconButton>
      )}
    </li>
  );
}

const fileIcon = (path: string) => {
  if (path.startsWith("image/")) return <ImageIcon className="size-3.5 shrink-0 text-muted-foreground" />;
  if (path.endsWith(".json")) return <FileJson className="size-3.5 shrink-0 text-muted-foreground" />;
  return <FileCode2 className="size-3.5 shrink-0 text-muted-foreground" />;
};

export function Sidebar({ projects, project, path, entry, onOpenProject, onDeleteProject, onOpenFile, onDeleteFile, onAddFile, onAddImage, onWallpaper }: SidebarProps) {
  return (
    <aside className="flex flex-col gap-4 overflow-auto bg-sidebar p-3" aria-label="Projects and files">
      <section className="flex flex-col gap-1.5">
        <SectionTitle>Projects</SectionTitle>
        <ul id="project-list" className="flex flex-col">
          {projects.map((item) => (
            <Row key={item.id} current={item.id === project.id} label={item.name} deleteLabel={`Delete ${item.name}`}
              onOpen={() => onOpenProject(item)} onDelete={() => onDeleteProject(item)} />
          ))}
        </ul>
      </section>
      <section className="flex flex-col gap-1.5">
        <div className="flex items-center justify-between">
          <SectionTitle>Files</SectionTitle>
          <IconButton id="add-file" label="Add file" className="size-7" onClick={onAddFile}><Plus className="size-4" /></IconButton>
        </div>
        <ul id="file-list" className="flex flex-col">
          {sortedPaths(project.files).map((name) => (
            <Row key={name} current={name === path} label={name} icon={fileIcon(name)} deleteLabel={`Delete ${name}`}
              onOpen={() => onOpenFile(name)}
              onDelete={name !== "widget.json" && name !== entry ? () => onDeleteFile(name) : undefined} />
          ))}
        </ul>
        <Button id="add-image" variant="link" size="sm" className="h-auto self-start px-2 py-1" onClick={onAddImage}>Add image…</Button>
        {onWallpaper && <Button id="open-wallpaper" variant="outline" size="sm" onClick={onWallpaper}>Wallpaper crops…</Button>}
      </section>
      <p className="mt-auto text-xs text-muted-foreground">Drafts are saved in this browser. Export a .swt file to keep a copy.</p>
    </aside>
  );
}
