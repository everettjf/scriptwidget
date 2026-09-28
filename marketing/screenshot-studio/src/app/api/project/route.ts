import { promises as fs } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { projectValidationError } from "@/lib/project-validation";
import { rejectCrossSiteWrite } from "@/lib/request-guard";

export const dynamic = "force-dynamic";

const PROJECT_FILE = "app-store-screenshots.json";

function filePath() {
  return path.join(process.cwd(), PROJECT_FILE);
}

export async function GET() {
  try {
    const raw = await fs.readFile(filePath(), "utf8");
    const parsed = JSON.parse(raw);
    const validationError = projectValidationError(parsed);
    if (validationError) throw new Error(validationError);
    return NextResponse.json({ ok: true, state: parsed });
  } catch (e) {
    const code = (e as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return NextResponse.json({ ok: true, state: null });
    }
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}

export async function POST(req: Request) {
  // This route OVERWRITES a git-tracked file. See lib/request-guard.ts.
  const blocked = rejectCrossSiteWrite(req);
  if (blocked) {
    return NextResponse.json({ ok: false, error: blocked.error }, { status: blocked.status });
  }
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ ok: false, error: "Invalid JSON" }, { status: 400 });
  }
  const validationError = projectValidationError(body);
  if (validationError) {
    return NextResponse.json({ ok: false, error: validationError }, { status: 400 });
  }
  const temporary = `${filePath()}.${randomUUID()}.tmp`;
  try {
    const pretty = JSON.stringify(body, null, 2) + "\n";
    // Readers must see either the previous complete project or the next one.
    await fs.writeFile(temporary, pretty, "utf8");
    await fs.rename(temporary, filePath());
    return NextResponse.json({ ok: true });
  } catch (e) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  } finally {
    await fs.unlink(temporary).catch(() => undefined);
  }
}
