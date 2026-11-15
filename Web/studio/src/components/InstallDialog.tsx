import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { productLinks } from "@/lib/productLinks";

export function InstallDialog({ fileName, onOpenChange }: { fileName: string | null; onOpenChange(open: boolean): void }) {
  return (
    <Dialog open={fileName !== null} onOpenChange={onOpenChange}>
      <DialogContent id="install-dialog" className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Install on iPhone</DialogTitle>
          <DialogDescription>{fileName} was downloaded. To install it:</DialogDescription>
        </DialogHeader>
        <ol className="ml-5 list-decimal space-y-1.5 text-sm">
          <li>Send the file to your iPhone with AirDrop, iCloud Drive, or email.</li>
          <li>On iPhone, open the file, tap Share, and choose ScriptWidget.</li>
          <li>Review the permissions, then add the widget from the Home Screen.</li>
        </ol>
        <p className="text-xs text-muted-foreground">Opening this page in Safari on iPhone lets you send it to ScriptWidget directly from the share sheet.</p>
        <p className="text-sm">
          Need the app?{" "}
          <a className="text-primary underline-offset-4 hover:underline" href={productLinks.ios} target="_blank" rel="noopener noreferrer">
            Get ScriptWidget on the App Store
          </a>
        </p>
      </DialogContent>
    </Dialog>
  );
}
