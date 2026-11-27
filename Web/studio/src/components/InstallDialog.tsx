import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { productLinks } from "@/lib/productLinks";

export function InstallDialog({ fileName, onOpenChange }: { fileName: string | null; onOpenChange(open: boolean): void }) {
  return (
    <Dialog open={fileName !== null} onOpenChange={onOpenChange}>
      <DialogContent id="install-dialog" className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Install on your device</DialogTitle>
          <DialogDescription>{fileName} was downloaded. Import the downloaded package in ScriptWidget.</DialogDescription>
        </DialogHeader>
        <ul className="ml-5 list-disc space-y-1.5 text-sm">
          <li><strong>iPhone and iPad:</strong> send the file with AirDrop, iCloud Drive, or email, open it, tap Share, and choose ScriptWidget.</li>
          <li><strong>Android:</strong> send the file to the device and open it with ScriptWidget.</li>
          <li><strong>Mac:</strong> import the file in ScriptWidget Studio. Add ScriptWidget from Edit Widgets on the desktop, then select your project in the widget settings.</li>
          <li><strong>Windows and Linux:</strong> use Import in the ScriptWidget library, then add the widget to the desktop.</li>
        </ul>
        <p className="text-sm">Review the permissions the widget asks for, then add it where your system keeps widgets.</p>
        <p className="text-xs text-muted-foreground">
          On iPhone and iPad, widgets require iOS or iPadOS 18 or later. Windows and Linux are previews.{" "}
          <a className="text-primary underline-offset-4 hover:underline" href={productLinks.platformSupport} target="_blank" rel="noopener noreferrer">Check platform support</a>
        </p>
        <p className="text-sm">
          Need the app?{" "}
          {([["iPhone and iPad", productLinks.ios], ["Mac", productLinks.mac], ["Android", productLinks.android], ["Windows", productLinks.windows], ["Linux", productLinks.linux]] as const).map(([name, link], index) => (
            <span key={name}>
              {index > 0 ? " · " : ""}
              <a className="text-primary underline-offset-4 hover:underline" href={link} target="_blank" rel="noopener noreferrer">{name}</a>
            </span>
          ))}
        </p>
      </DialogContent>
    </Dialog>
  );
}
