import { ChevronDown, ExternalLink, Globe, MessageCircle, Monitor, Smartphone } from "lucide-react";
import { DropdownMenu } from "radix-ui";
import { Button } from "@/components/ui/button";
import { productLinks } from "@/lib/productLinks";

const links = [
  { href: productLinks.ios, name: "iOS & iPadOS", detail: "Download on the App Store", icon: Smartphone },
  { href: productLinks.mac, name: "macOS", detail: "Download on the Mac App Store", icon: Monitor },
  { href: productLinks.android, name: "Android APK", detail: "GitHub release · Android 13+", icon: Smartphone },
  { href: productLinks.windows, name: "Windows (preview)", detail: "Microsoft Store · Windows 11", icon: Monitor },
  { href: productLinks.linux, name: "Linux (preview)", detail: "GitHub release · Omarchy 4.5", icon: Monitor },
  { href: productLinks.website, name: "Official website", detail: "ScriptWidget home", icon: Globe },
  { href: productLinks.discord, name: "Discord community", detail: "Discuss widgets and get help", icon: MessageCircle },
];

// The entries before the separator are downloads; the rest are places to go.
const downloads = links.findIndex((link) => link.href === productLinks.website);

export function ProductLinks() {
  return (
    <nav className="order-2 ml-auto xl:order-4" aria-label="ScriptWidget links">
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <Button id="product-links" variant="ghost" size="sm">Get the app<ChevronDown aria-hidden="true" /></Button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content align="end" sideOffset={8}
            className="z-50 max-h-[var(--radix-dropdown-menu-content-available-height)] w-72 max-w-[calc(100vw-24px)] overflow-auto rounded-lg border bg-popover p-1.5 text-popover-foreground shadow-lg">
            <DropdownMenu.Label className="px-2 py-1.5 text-xs font-medium text-muted-foreground">Download ScriptWidget</DropdownMenu.Label>
            {links.map(({ href, name, detail, icon: Icon }, index) => (
              <div key={href}>
                {index === downloads && <DropdownMenu.Separator className="my-1 h-px bg-border" />}
                <DropdownMenu.Item asChild>
                  <a href={href} target="_blank" rel="noopener noreferrer"
                    className="flex items-center gap-3 rounded-md px-2 py-2.5 outline-none data-highlighted:bg-accent data-highlighted:text-accent-foreground">
                    <Icon className="size-4 shrink-0" aria-hidden="true" />
                    <span className="flex-1"><span className="block text-sm font-medium">{name}</span><span className="block text-xs text-muted-foreground">{detail}</span></span>
                    <ExternalLink className="size-3 text-muted-foreground" aria-hidden="true" />
                  </a>
                </DropdownMenu.Item>
              </div>
            ))}
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
    </nav>
  );
}
