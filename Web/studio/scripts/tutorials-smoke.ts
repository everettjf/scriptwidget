// Run against the deployed site layout after `node Scripts/build-web-site.mjs`.
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { chromium, firefox, webkit, type Locator, type Page } from "playwright";
import { importPackage } from "../../preview-engine/src/package/index.js";
import { serveDirectory } from "../../preview-engine/scripts/lib/chrome.mjs";

const root = path.resolve(import.meta.dirname, "../../..");
const output = process.env.SCRIPTWIDGET_TUTORIAL_SCREENSHOTS;
const browsers = { chromium, firefox, webkit };
const lessonIDs = ["hello-world", "event-countdown", "interactive-todo", "weather-forecast", "calendar-agenda"];
const requested = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(browsers);
const timeout = 30_000;

type Scheme = "light" | "dark";

const guide = (page: Page) => page.locator("#tutorial-guide");
const stepAction = (page: Page) => guide(page).getByTestId("tutorial-step-action");
const learn = (page: Page) => page.getByRole("button", { name: "Learn", exact: true });
const hub = (page: Page) => page.getByRole("dialog", { name: "Learn Web Studio" });
const lessonCard = (page: Page, id: string) => hub(page).locator(`[data-tutorial-id="${id}"]`);
const editor = (page: Page) => page.locator("#editor .cm-content");
const countProjects = (page: Page) => page.locator("#project-list li").count();
const activeProject = (page: Page) => page.evaluate(() => JSON.parse(localStorage.getItem("scriptwidget-studio.project") ?? "null") as string | null);

async function screenshot(page: Page, name: string) {
  if (output) await page.screenshot({ path: path.join(output, `${name}.png`), animations: "disabled", fullPage: true });
}

async function setScheme(page: Page, scheme: Scheme) {
  await page.emulateMedia({ colorScheme: scheme, reducedMotion: "reduce" });
  await page.waitForFunction(appearance => document.documentElement.style.colorScheme === appearance, scheme);
  await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
}

async function waitForWidgetScheme(widget: Locator, scheme: Scheme) {
  await widget.and(widget.page().locator(`.sw-widget[style*="color-scheme: ${scheme}"]`)).waitFor();
}

async function verifyContrast(surface: Locator, label: string) {
  const measured = await surface.evaluate(root => {
    // Resolve browser CSS colors, including OKLCH and translucent layers, to
    // their final sRGB values before comparing visible text with its surface.
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 1;
    const pixel = canvas.getContext("2d", { willReadFrequently: true })!;
    const luminance = () => {
      const rgb = [...pixel.getImageData(0, 0, 1, 1).data].slice(0, 3).map(value => {
        const srgb = value / 255;
        return srgb <= 0.04045 ? srgb / 12.92 : ((srgb + 0.055) / 1.055) ** 2.4;
      });
      return rgb[0]! * 0.2126 + rgb[1]! * 0.7152 + rgb[2]! * 0.0722;
    };
    const fill = (color: string) => { pixel.fillStyle = color; pixel.fillRect(0, 0, 1, 1); };
    function background(element: Element) {
      const layers: string[] = [];
      for (let current: Element | null = element; current; current = current.parentElement) {
        layers.push(getComputedStyle(current).backgroundColor);
      }
      fill(getComputedStyle(document.documentElement).colorScheme === "dark" ? "black" : "white");
      for (const layer of layers.reverse()) fill(layer);
      return luminance();
    }
    const textWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const text = [];
    const range = document.createRange();
    for (let node = textWalker.nextNode(); node; node = textWalker.nextNode()) {
      const element = node.parentElement;
      const label = node.textContent?.trim();
      if (!label || !element || element.closest("style, script, .sr-only, :disabled, [aria-disabled=true]")) continue;
      if (getComputedStyle(element).visibility !== "visible") continue;
      range.selectNodeContents(node);
      if (!range.getClientRects().length) continue;
      const back = background(element);
      fill(getComputedStyle(element).color);
      const front = luminance();
      text.push({ label, ratio: (Math.max(back, front) + 0.05) / (Math.min(back, front) + 0.05) });
    }
    return { background: background(root), text };
  });
  assert.ok(measured.text.length, `${label} must have visible text`);
  const unreadable = measured.text.filter(sample => sample.ratio < 4.5);
  assert.deepEqual(unreadable.map(sample => `${sample.label} (${sample.ratio.toFixed(2)}:1)`), [], `${label} needs at least 4.5:1 contrast for text`);
  return measured.background;
}

async function verifyWidgetThemes(page: Page, name: string) {
  const widget = page.locator("#stage .sw-widget");
  await setScheme(page, "light");
  await waitForWidgetScheme(widget, "light");
  const light = await verifyContrast(widget, `${name} light preview`);
  await screenshot(page, `${name}-light`);
  await setScheme(page, "dark");
  await waitForWidgetScheme(widget, "dark");
  const dark = await verifyContrast(widget, `${name} dark preview`);
  assert.ok(dark < light, `${name} must use a darker background in Dark appearance`);
  await screenshot(page, `${name}-dark`);
}

async function chooseAppearance(page: Page, label: "System" | "Light" | "Dark") {
  await page.locator("#appearance").click();
  await page.getByRole("option", { name: label, exact: true }).click();
  await page.getByRole("listbox").waitFor({ state: "hidden" });
}

async function step(page: Page, id: string) {
  await page.locator(`#tutorial-guide[data-step-id="${id}"]`).waitFor();
}

async function complete(page: Page, count: number) {
  const lesson = page.locator(`#tutorial-guide[data-completed-count="${count}"]`);
  await lesson.getByRole("heading", { name: "Lesson complete" }).waitFor();
}

async function rendered(page: Page, text: string) {
  await page.waitForFunction((expected) =>
    document.querySelector("#stage .sw-widget")?.textContent?.replace(/\s+/g, " ").includes(expected), text);
}

async function saved(page: Page) {
  await page.locator("#save-state").filter({ hasText: /^Saved in this browser$/ }).waitFor();
}

async function replaceSource(page: Page, source: string) {
  const content = editor(page);
  await content.focus();
  await content.press("ControlOrMeta+a");
  await page.keyboard.insertText(source);
}

async function editSource(page: Page, previous: string, next: string) {
  // Export reads the complete editor draft. CodeMirror only mounts visible
  // lines, so extracting source from its DOM can truncate longer examples.
  const file = await page.locator("#current-file").textContent();
  assert.ok(file);
  const { files } = await downloadedPackage(page, () => page.locator("#export-package").click());
  const source = files[file];
  assert.ok(typeof source === "string");
  assert.ok(source.includes(previous), `The lesson source must contain ${previous}`);
  await replaceSource(page, source.replace(previous, next));
}

async function openLearn(page: Page) {
  await learn(page).press("Enter");
  await hub(page).waitFor();
}

async function startLesson(page: Page, id: string, firstStep: string, starterButton?: Locator) {
  const priorID = await activeProject(page);
  const priorCount = await countProjects(page);
  if (starterButton) await starterButton.press("Enter");
  else {
    await openLearn(page);
    const card = lessonCard(page, id);
    assert.match(await card.getAttribute("aria-label") ?? "", /^Start /);
    await card.press("Enter");
    await page.locator("#tutorials-dialog").waitFor({ state: "detached" });
  }
  await step(page, firstStep);
  await page.waitForFunction(() => document.activeElement?.id === "tutorial-heading");
  assert.equal(await guide(page).getAttribute("data-lesson-id"), id);
  const projectID = await activeProject(page);
  assert.ok(projectID && projectID !== priorID, "Starting a lesson must open a separate project");
  assert.equal(await countProjects(page), priorCount + 1);
  return projectID;
}

async function downloadedPackage(page: Page, trigger: () => Promise<void>) {
  const [download] = await Promise.all([page.waitForEvent("download"), trigger()]);
  assert.match(download.suggestedFilename(), /\.swt$/i);
  const imported = await importPackage(await fs.readFile(await download.path()));
  assert.equal(imported.error, undefined);
  assert.ok(imported.manifest && imported.files);
  return { manifest: imported.manifest, files: imported.files };
}

async function verifyInactiveFileAndConfirmation(page: Page, name: string, original: string) {
  await page.setViewportSize({ width: 1440, height: 1000 });
  const sidebar = page.getByRole("complementary", { name: "Projects and files" });
  await sidebar.getByRole("button", { name: "My First Widget", exact: true }).click();
  await page.getByRole("textbox", { name: "Edit main.jsx", exact: true }).waitFor();
  await setScheme(page, "dark");
  await sidebar.getByRole("button", { name: "Delete My First Widget" }).click();
  const confirmation = page.getByRole("alertdialog");
  await confirmation.waitFor();
  const darkConfirmation = await verifyContrast(confirmation, `${name} dark delete confirmation`);
  await setScheme(page, "light");
  const lightConfirmation = await verifyContrast(confirmation, `${name} light delete confirmation`);
  assert.ok(darkConfirmation < lightConfirmation, "The confirmation must follow the Studio theme");
  await confirmation.getByRole("button", { name: "Cancel", exact: true }).click();
  await confirmation.waitFor({ state: "hidden" });
  assert.equal(await activeProject(page), original);

  // Changing appearance while another file is open preserves its undo history.
  const initialSource = (await editor(page).locator(".cm-line").allTextContents()).join("\n");
  await replaceSource(page, `${initialSource}\n// Preserve this edit`);
  await sidebar.getByRole("button", { name: "widget.json", exact: true }).click();
  await page.locator("#current-file").filter({ hasText: /^widget\.json$/ }).waitFor();
  await setScheme(page, "dark");
  await sidebar.getByRole("button", { name: "main.jsx", exact: true }).click();
  await page.getByRole("textbox", { name: "Edit main.jsx", exact: true }).waitFor();
  await editor(page).press("ControlOrMeta+z");
  assert.equal((await editor(page).locator(".cm-line").allTextContents()).join("\n"), initialSource);
}

async function exercise(page: Page, url: string, name: string) {
  const errors: string[] = [];
  const remoteRequests: string[] = [];
  const origin = new URL(url).origin;
  page.on("pageerror", error => errors.push(error.stack ?? error.message));
  page.on("request", request => {
    const target = new URL(request.url());
    if ((target.protocol === "https:" || target.protocol === "http:") && target.origin !== origin) remoteRequests.push(target.origin);
  });
  // Exercise the download path even on browsers with an OS share sheet.
  await page.addInitScript(() => Object.defineProperty(navigator, "canShare", { configurable: true, value: () => false }));
  await page.goto(url);
  await page.locator("#starter-guide").waitFor();
  await page.locator("#stage .sw-widget").waitFor();
  const original = await activeProject(page);
  assert.ok(original);
  const starter = page.locator("#starter-guide");
  const toolbar = page.getByRole("banner");
  const mainWidget = page.locator("#stage .sw-widget");
  assert.equal(await page.locator("#appearance").textContent(), "System");
  await waitForWidgetScheme(mainWidget, "dark");
  const darkStarter = await verifyContrast(starter, `${name} dark starter`);
  await verifyContrast(toolbar, `${name} dark toolbar`);
  const darkEditor = await verifyContrast(editor(page), `${name} dark editor code`);
  await screenshot(page, `${name}-starter-dark`);
  await setScheme(page, "light");
  await waitForWidgetScheme(mainWidget, "light");
  const lightStarter = await verifyContrast(starter, `${name} light starter`);
  assert.ok(darkStarter < lightStarter, "The starter panel must follow the Studio theme");
  await verifyContrast(toolbar, `${name} light toolbar`);
  const lightEditor = await verifyContrast(editor(page), `${name} light editor code`);
  assert.ok(darkEditor < lightEditor, "The editor surface must follow the Studio theme");
  await screenshot(page, `${name}-starter-light`);

  // Open the toolbar with the keyboard, verify all five choices, then return to the draft.
  await openLearn(page);
  assert.deepEqual(await hub(page).locator("[data-tutorial-id]").evaluateAll(cards => cards.map(card => card.getAttribute("data-tutorial-id"))), lessonIDs);
  assert.equal(await countProjects(page), 1);
  const lightLearn = await verifyContrast(hub(page), `${name} light Learn dialog`);
  await screenshot(page, `${name}-learn-light`);
  await setScheme(page, "dark");
  await waitForWidgetScheme(mainWidget, "dark");
  const darkLearn = await verifyContrast(hub(page), `${name} dark Learn dialog`);
  assert.ok(darkLearn < lightLearn, "The Learn dialog must follow the Studio theme");
  await screenshot(page, `${name}-learn-dark`);
  await page.keyboard.press("Escape");
  await hub(page).waitFor({ state: "hidden" });
  await page.waitForFunction(() => document.activeElement?.id === "open-tutorials");
  assert.equal(await activeProject(page), original);

  // Explicit widget appearances stay independent of the editor and its dialogs.
  await chooseAppearance(page, "Light");
  await waitForWidgetScheme(mainWidget, "light");
  assert.equal(await page.locator("html").evaluate(node => node.style.colorScheme), "dark");
  await setScheme(page, "light");
  await chooseAppearance(page, "Dark");
  await waitForWidgetScheme(mainWidget, "dark");
  assert.equal(await page.locator("html").evaluate(node => node.style.colorScheme), "light");
  await chooseAppearance(page, "System");
  await waitForWidgetScheme(mainWidget, "light");
  await setScheme(page, "dark");
  await waitForWidgetScheme(mainWidget, "dark");

  const firstWidget = page.locator("#starter-guide").getByRole("button", { name: "Build your first widget" });
  const helloProject = await startLesson(page, "hello-world", "change-text", firstWidget);
  await rendered(page, "Hello, world!");
  const helloSource = (await editor(page).locator(".cm-line").allTextContents()).join("\n");
  await replaceSource(page, "$render(<text>\n");
  await page.waitForFunction(() => /failed|error/i.test(document.getElementById("preview-status")?.textContent ?? ""));
  await guide(page).getByRole("alert").filter({ hasText: /Check the preview or Problems/ }).waitFor();
  await verifyContrast(guide(page), `${name} dark guide error`);
  await verifyContrast(page.locator("#stage"), `${name} dark runtime error`);
  await setScheme(page, "light");
  await verifyContrast(guide(page), `${name} light guide error`);
  await verifyContrast(page.locator("#stage"), `${name} light runtime error`);
  await setScheme(page, "dark");
  await step(page, "change-text");
  assert.notEqual(helloSource.replace('const name = "world";', 'const name = "Studio";'), helloSource);
  await replaceSource(page, helloSource.replace('const name = "world";', 'const name = "Studio";'));
  await rendered(page, "Hello, Studio!");
  await step(page, "add-caption");
  await guide(page).getByRole("button", { name: "Hide guide" }).press("Enter");
  await guide(page).getByRole("button", { name: "Show guide" }).waitFor();
  await saved(page);
  await page.reload();
  assert.equal(await activeProject(page), helloProject);
  await guide(page).getByRole("button", { name: "Show guide" }).press("Enter");
  await step(page, "add-caption");
  await guide(page).getByTestId("tutorial-edit").press("Enter");
  const caption = await guide(page).locator("pre code").textContent();
  assert.ok(caption);
  await editSource(page, "</vstack>", `${caption}\n  </vstack>`);
  await rendered(page, "Built in JavaScript");
  await complete(page, 2);
  await verifyContrast(guide(page), `${name} dark Hello World guide`);
  await verifyWidgetThemes(page, `${name}-hello-world`);
  await saved(page);

  await startLesson(page, "event-countdown", "name-event");
  await rendered(page, "2030-06-15");
  await editSource(page, 'const eventName = "My event";', 'const eventName = "Launch day";');
  await rendered(page, "Launch day");
  await step(page, "change-date");
  await editSource(page, 'const targetDate = "2030-06-15";', 'const targetDate = "2030-06-22";');
  await rendered(page, "2030-06-22");
  await step(page, "compare-sizes");
  assert.match(await page.locator("#family").textContent() ?? "", /Small/);
  await stepAction(page).press("Enter");
  await complete(page, 3);
  await rendered(page, "Launch day");
  assert.match(await page.locator("#family").textContent() ?? "", /Medium/);
  await verifyWidgetThemes(page, `${name}-event-countdown`);

  const todoProject = await startLesson(page, "interactive-todo", "bind-button");
  await editSource(page, 'const firstTaskAction = "";', 'const firstTaskAction = "toggleOne";');
  await step(page, "check-task");
  await rendered(page, "0/5");
  await stepAction(page).press("Enter");
  await step(page, "reload-list");
  await rendered(page, "1/5");
  await page.waitForFunction(() => !!document.activeElement?.closest("#tutorial-guide"));
  await verifyWidgetThemes(page, `${name}-interactive-todo`);
  await saved(page);
  await guide(page).getByRole("button", { name: "Reload Studio" }).press("Enter");
  await step(page, "undo-task");
  assert.equal(await activeProject(page), todoProject);
  await rendered(page, "1/5");
  await stepAction(page).press("Enter");
  await rendered(page, "0/5");
  await complete(page, 4);
  const todo = await downloadedPackage(page, () => guide(page).getByRole("button", { name: "Install on device" }).click());
  assert.match(String(todo.files["main.jsx"]), /const firstTaskAction = "toggleOne";/);
  assert.ok(todo.manifest.permissions.includes("storage"));
  assert.ok(todo.manifest.actions?.some(action => action.id === "toggleOne"));
  assert.equal(Object.keys(todo.files).some(file => /mock|fixture|progress/i.test(file)), false);
  assert.equal(Object.keys(todo.manifest).some(key => /tutorial|mock|fixture|progress/i.test(key)), false);
  const install = page.getByRole("dialog", { name: "Install on your device" });
  await install.getByText(/was downloaded\. Import the downloaded package in ScriptWidget\./).waitFor();
  const darkInstall = await verifyContrast(install, `${name} dark Install dialog`);
  await setScheme(page, "light");
  const lightInstall = await verifyContrast(install, `${name} light Install dialog`);
  assert.ok(darkInstall < lightInstall, "The Install dialog must follow the Studio theme");
  await setScheme(page, "dark");
  await page.keyboard.press("Escape");
  await install.waitFor({ state: "hidden" });

  const beforeCloud = await countProjects(page);
  await guide(page).getByRole("button", { name: "Try the iCloud version" }).click();
  const cloud = page.getByRole("region", { name: "Try an iCloud to-do list" });
  await cloud.getByText("Simulated iCloud", { exact: true }).waitFor();
  assert.equal(await countProjects(page), beforeCloud + 1);
  assert.notEqual(await activeProject(page), todoProject);
  await rendered(page, "1/2");
  await cloud.getByRole("button", { name: "Empty store" }).press("Enter");
  await rendered(page, "0/2");
  await cloud.getByRole("button", { name: "Saved list" }).press("Enter");
  await rendered(page, "1/2");
  await verifyWidgetThemes(page, `${name}-icloud-todo`);
  await page.getByRole("tab", { name: "Mock Data", exact: true }).press("Enter");
  assert.equal(await page.getByRole("combobox", { name: "Action to simulate" }).textContent(), "Add sample task");
  await page.getByRole("button", { name: "Run simulated action" }).press("Enter");
  await page.getByText(/iCloud writes last for this run/).waitFor();
  await rendered(page, "1/2");
  await verifyContrast(page.getByRole("tablist"), `${name} dark preview tabs`);
  await verifyContrast(page.getByRole("tabpanel", { name: "Mock Data" }), `${name} dark mock data controls`);
  await cloud.getByRole("button", { name: "Read the tutorial" }).press("Enter");
  await page.locator("#current-file").filter({ hasText: /^README\.md$/ }).waitFor();
  const cloudExport = await downloadedPackage(page, () => cloud.getByRole("button", { name: "Install on device" }).click());
  assert.ok(cloudExport.manifest.permissions.includes("icloud"));
  assert.ok(cloudExport.files["README.md"]);
  assert.equal(Object.hasOwn(cloudExport.files, "todo.json"), false, "Sample iCloud documents must remain in the browser");
  await page.keyboard.press("Escape");
  await install.waitFor({ state: "hidden" });

  await startLesson(page, "weather-forecast", "sunny");
  await stepAction(page).press("Enter");
  await rendered(page, "Sunny · 22°C");
  await step(page, "show-hour");
  await guide(page).getByTestId("tutorial-edit").press("Enter");
  await editSource(page, "upcoming.slice(0, 2)", "upcoming.slice(0, 3)");
  await rendered(page, "25°C");
  await step(page, "rain");
  await stepAction(page).press("Enter");
  await rendered(page, "Rain · 14°C");
  await verifyWidgetThemes(page, `${name}-weather-forecast`);
  await step(page, "offline");
  await stepAction(page).press("Enter");
  await rendered(page, "Forecast unavailable");
  await complete(page, 4);
  await verifyWidgetThemes(page, `${name}-weather-fallback`);

  const calendarProject = await startLesson(page, "calendar-agenda", "declare-access");
  await guide(page).getByTestId("tutorial-edit").press("Enter");
  await page.locator("#current-file").filter({ hasText: /^widget\.json$/ }).waitFor();
  await editSource(page, '"permissions": []', '"permissions": ["calendar"]');
  await rendered(page, "Design review");
  await step(page, "no-events");
  await stepAction(page).press("Enter");
  await rendered(page, "No events today");
  await step(page, "denied");
  await stepAction(page).press("Enter");
  await rendered(page, "Connect Calendar");
  await step(page, "restore");
  await saved(page);

  // Switching to an existing draft must hide the guide, and Learn should find
  // the in-progress calendar lesson without creating a duplicate project.
  await page.locator("#project-list").getByRole("button", { name: "My First Widget", exact: true }).click();
  await guide(page).waitFor({ state: "detached" });
  assert.equal(await activeProject(page), original);
  const beforeResuming = await countProjects(page);
  await openLearn(page);
  assert.match(await lessonCard(page, "calendar-agenda").getAttribute("aria-label") ?? "", /^Resume /);
  assert.match(await lessonCard(page, "hello-world").getAttribute("aria-label") ?? "", /^Open /);
  await lessonCard(page, "calendar-agenda").press("Enter");
  await step(page, "restore");
  assert.equal(await activeProject(page), calendarProject);
  assert.equal(await countProjects(page), beforeResuming);

  await page.setViewportSize({ width: 390, height: 844 });
  await stepAction(page).press("Enter");
  await rendered(page, "Design review");
  await complete(page, 4);
  await verifyWidgetThemes(page, `${name}-calendar-agenda`);
  await page.evaluate(async () => { await document.fonts.ready; scrollTo(0, 0); });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "Mobile Studio must not overflow horizontally");
  assert.ok(await page.evaluate(() => {
    const preview = document.querySelector("#stage .sw-widget")?.getBoundingClientRect();
    return preview && preview.top >= 0 && preview.bottom <= innerHeight;
  }), "The widget must be visible with the tutorial at the top of the mobile viewport");
  const previewSettings = page.locator("summary").filter({ hasText: /^Preview settings$/ });
  await page.locator("#family").waitFor({ state: "hidden" });
  await previewSettings.press("Enter");
  await page.locator("#family").waitFor();
  await previewSettings.press("Enter");
  await page.locator("#family").waitFor({ state: "hidden" });

  // Existing project actions still work with a completed lesson open.
  await page.getByRole("button", { name: "Gallery", exact: true }).click();
  const gallery = page.getByRole("dialog", { name: "Gallery" });
  await gallery.locator("#template-search").fill("Calendar Agenda");
  const calendarCard = gallery.locator(".template-card").filter({ hasText: "Calendar Agenda" });
  const cardWidget = calendarCard.locator(".sw-widget");
  await waitForWidgetScheme(cardWidget, "dark");
  await verifyContrast(calendarCard, `${name} dark Gallery card`);
  await calendarCard.click();
  const detailWidget = gallery.locator("#template-detail .sw-widget");
  await waitForWidgetScheme(detailWidget, "dark");
  const darkGallery = await verifyContrast(detailWidget, `${name} dark Gallery detail preview`);
  await setScheme(page, "light");
  await waitForWidgetScheme(detailWidget, "light");
  const lightGallery = await verifyContrast(detailWidget, `${name} light Gallery detail preview`);
  assert.ok(darkGallery < lightGallery, "The Gallery preview must follow the selected widget appearance");
  await page.keyboard.press("Escape");
  await gallery.waitFor({ state: "hidden" });
  await page.getByRole("button", { name: "New", exact: true }).click();
  await guide(page).waitFor({ state: "detached" });
  assert.equal(await countProjects(page), beforeResuming + 1);
  await page.locator("#project-list").getByRole("button", { name: "Hello World", exact: true }).click();
  await complete(page, 2);
  assert.equal(await activeProject(page), helloProject);
  await rendered(page, "Built in JavaScript");
  await verifyInactiveFileAndConfirmation(page, name, original);
  assert.deepEqual(remoteRequests, [], "Tutorial sample data must stay in the browser");
  assert.deepEqual(errors, []);
}

async function exerciseMemoryOnly(page: Page, url: string) {
  await page.addInitScript(() => Object.defineProperty(window, "indexedDB", { value: undefined }));
  await page.goto(url);
  await page.locator("#stage .sw-widget").waitFor();
  await startLesson(page, "interactive-todo", "bind-button");
  await editSource(page, 'const firstTaskAction = "";', 'const firstTaskAction = "toggleOne";');
  await step(page, "check-task");
  await stepAction(page).press("Enter");
  await step(page, "reload-list");
  await rendered(page, "1/5");
  await guide(page).getByText(/Browser storage is unavailable\. Reloading would lose this draft/).waitFor();
  assert.equal(await guide(page).getByRole("button", { name: "Reload Studio" }).count(), 0);
  await guide(page).getByRole("button", { name: "Skip reload check" }).press("Enter");
  await step(page, "undo-task");
  await stepAction(page).press("Enter");
  await rendered(page, "0/5");
  await complete(page, 4);
  await guide(page).getByText("The reload check was skipped because browser storage was unavailable.").waitFor();
}

if (output) await fs.mkdir(output, { recursive: true });
const site = path.join(root, "_site");
await fs.access(path.join(site, "studio/index.html"));
const directory = await fs.mkdtemp(path.join(os.tmpdir(), "scriptwidget-tutorials-"));
try {
  // Keep the actual Pages subpath; relative links, helper scripts, the sandbox
  // and catalog all load from the same layout as production.
  await fs.cp(site, path.join(directory, "scriptwidget"), { recursive: true });
  const server = await serveDirectory(directory);
  try {
    for (const name of requested) {
      assert.ok(Object.hasOwn(browsers, name), `Unknown browser: ${name}`);
      const browser = await browsers[name as keyof typeof browsers].launch();
      try {
        const url = `${server.origin}/scriptwidget/studio/`;
        const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, locale: "en-US", timezoneId: "UTC", acceptDownloads: true, colorScheme: "dark", reducedMotion: "reduce" });
        page.setDefaultTimeout(timeout);
        await exercise(page, url, name);
        console.log(`${name}: light and dark Studio, five lessons and iCloud, resume and recovery, keyboard, mobile, and package export passed.`);
        if (name === "chromium") {
          const privatePage = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
          privatePage.setDefaultTimeout(timeout);
          await exerciseMemoryOnly(privatePage, url);
          console.log(`${name}: the to-do guide finished with the reload check explicitly skipped in a memory-only project.`);
        }
      } finally { await browser.close(); }
    }
  } finally { server.close(); }
} finally { await fs.rm(directory, { recursive: true, force: true }); }
