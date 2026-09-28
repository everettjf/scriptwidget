import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { NextResponse } from "next/server";
import { rejectCrossSiteWrite } from "@/lib/request-guard";
import type { ImportedFont } from "@/lib/types";

export const dynamic = "force-dynamic";

const FONT_DIR_REL = path.join("public", "fonts", "imported");
const PUBLIC_PREFIX = "/fonts/imported";
const MAX_FONT_BYTES = 16 * 1024 * 1024;

const FONT_EXT: Record<ImportedFont["format"], string> = {
  woff2: "woff2",
  woff: "woff",
  truetype: "ttf",
  opentype: "otf",
};

// The stored format and extension come from the file's magic bytes, never
// from the caller-supplied filename or MIME type.
function sniffFontFormat(bytes: Buffer): ImportedFont["format"] | null {
  if (bytes.length < 4) return null;
  const tag = bytes.subarray(0, 4);
  if (tag.equals(Buffer.from("wOF2", "latin1"))) return "woff2";
  if (tag.equals(Buffer.from("wOFF", "latin1"))) return "woff";
  if (tag.equals(Buffer.from([0x00, 0x01, 0x00, 0x00])) || tag.equals(Buffer.from("true", "latin1"))) {
    return "truetype";
  }
  if (tag.equals(Buffer.from("OTTO", "latin1"))) return "opentype";
  return null;
}

export async function POST(req: Request) {
  // This route WRITES A FILE to disk. See lib/request-guard.ts.
  const blocked = rejectCrossSiteWrite(req);
  if (blocked) {
    return NextResponse.json({ ok: false, error: blocked.error }, { status: blocked.status });
  }
  let body: { data?: unknown };
  try {
    body = (await req.json()) as { data?: unknown };
  } catch {
    return NextResponse.json({ ok: false, error: "Invalid JSON" }, { status: 400 });
  }
  if (typeof body?.data !== "string" || !body.data) {
    return NextResponse.json({ ok: false, error: "Choose a font file first." }, { status: 400 });
  }
  // Reject oversized payloads before decoding (base64 is ~4/3 of the byte size).
  if (body.data.length > Math.ceil(MAX_FONT_BYTES / 3) * 4) {
    return NextResponse.json({ ok: false, error: "Font file is too large (16MB maximum)." }, { status: 413 });
  }
  const bytes = Buffer.from(body.data, "base64");
  if (bytes.byteLength > MAX_FONT_BYTES) {
    return NextResponse.json({ ok: false, error: "Font file is too large (16MB maximum)." }, { status: 413 });
  }
  const format = sniffFontFormat(bytes);
  if (!format) {
    return NextResponse.json({ ok: false, error: "Use a WOFF2, WOFF, TTF, or OTF font file." }, { status: 400 });
  }

  const hash = createHash("sha1").update(bytes).digest("hex").slice(0, 16);
  const filename = `${hash}.${FONT_EXT[format]}`;
  const absDir = path.join(process.cwd(), FONT_DIR_REL);
  const absFile = path.join(absDir, filename);

  try {
    await fs.mkdir(absDir, { recursive: true });
    try {
      await fs.access(absFile);
    } catch {
      await fs.writeFile(absFile, bytes);
    }
    const font: ImportedFont = { src: `${PUBLIC_PREFIX}/${filename}`, format };
    return NextResponse.json({ ok: true, font });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}
