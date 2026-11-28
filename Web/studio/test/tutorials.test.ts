import assert from "node:assert/strict";
import test from "node:test";
import { executePackageInNode } from "../../preview-engine/src/node.js";
import { exportPackage, importPackage } from "../../preview-engine/src/package/index.js";
import { parseMocks } from "../src/mockData.ts";
import { packageReport, type Project } from "../src/project.ts";
import { createTutorialProject, tutorials, tutorialScenario, tutorialSourceChanged } from "../src/tutorials.ts";

function edit(project: Project, file: string, from: string, to: string): Project {
  const source = project.files[file];
  assert.ok(typeof source === "string");
  assert.ok(source.includes(from), `Could not find ${from} in ${file}`);
  return { ...project, files: { ...project.files, [file]: source.replace(from, to) } };
}

async function run(project: Project, options: { family?: "small" | "medium"; actionID?: string; date?: string } = {}) {
  const report = packageReport(project);
  assert.ok(report.valid);
  const result = await executePackageInNode({
    files: project.files, manifest: report.manifest,
    fixtures: parseMocks(project.fixtures), actionID: options.actionID,
    environments: {
      "widget-size": options.actionID ? "action" : options.family ?? "medium",
      ...(options.date ? { "timeline-date": options.date } : {}),
    },
  });
  assert.equal(result.error, null);
  assert.ok(result.tree);
  return { ...result, tree: result.tree };
}

test("all five tutorials create independently named, exportable packages without browser fixtures", async () => {
  assert.equal(tutorials.length, 5);
  assert.equal(new Set(tutorials.map(({ id }) => id)).size, 5);
  for (const lesson of tutorials) {
    const project = createTutorialProject(lesson.id);
    const other = createTutorialProject(lesson.id);
    assert.notEqual(project.id, other.id);
    assert.notEqual(packageReport(project).manifest?.id, packageReport(other).manifest?.id);
    assert.equal(tutorialSourceChanged(lesson.id, project), false);
    const exported = exportPackage(project.files);
    assert.ok(exported.error === undefined);
    const imported = await importPackage(exported.bytes);
    assert.ok(imported.error === undefined);
    assert.deepEqual(imported.files, project.files);
  }
});

test("Hello and Countdown instructions produce the promised source-driven render changes", async () => {
  const hello = createTutorialProject("hello-world");
  const changedHello = edit(hello, "main.jsx", '"world"', '"Studio"');
  assert.equal(tutorialSourceChanged("hello-world", changedHello), true);
  const greeting = await run(changedHello);
  assert.match(greeting.tree, /Hello, .*Studio.*!/);
  const caption = tutorials.find(({ id }) => id === "hello-world")?.steps.find(({ id }) => id === "add-caption")?.code;
  assert.ok(caption);
  const withCaption = edit(changedHello, "main.jsx", "</vstack>", `${caption}\n  </vstack>`);
  assert.match((await run(withCaption)).tree, /Built in JavaScript/);

  const countdown = edit(createTutorialProject("event-countdown"), "main.jsx", "My event", "Launch day");
  const date = new Date(2030, 5, 15, 12).toISOString();
  const original = await run(countdown, { family: "small", date });
  assert.match(original.tree, /Today/);
  const moved = edit(countdown, "main.jsx", "2030-06-15", "2030-06-22");
  for (const family of ["small", "medium"] as const) {
    const changed = await run(moved, { family, date });
    assert.match(changed.tree, /Launch day/);
    assert.match(changed.tree, /2030-06-22/);
    assert.match(changed.tree, /7 days left/);
  }
});

test("the To-Do button delegates to its declared action and renders restored storage", async () => {
  const initial = createTutorialProject("interactive-todo");
  const before = await run(initial);
  assert.doesNotMatch(before.tree, /"actionID":"toggleOne"/);
  const bound = edit(initial, "main.jsx", 'firstTaskAction = ""', 'firstTaskAction = "toggleOne"');
  const ready = await run(bound, { family: "small" });
  assert.match(ready.tree, /"actionID":"toggleOne"/);
  assert.match(ready.tree, /0\/5/);

  const checked = await run(bound, { actionID: "toggleOne" });
  assert.ok(checked.mockState);
  const saved = { ...bound, fixtures: JSON.stringify(checked.mockState) };
  assert.match((await run(saved)).tree, /1\/5/);

  const unchecked = await run(saved, { actionID: "toggleOne" });
  assert.ok(unchecked.mockState);
  const restored = await run({ ...saved, fixtures: JSON.stringify(unchecked.mockState) });
  assert.match(restored.tree, /0\/5/);
});

test("the Weather exercise changes the temperature and icon then shows its error state", async () => {
  const project = createTutorialProject("weather-forecast");
  const initial = await run(project);
  assert.match(initial.tree, /Sunny · 22°C/);
  assert.match(initial.tree, /sun\.max\.fill/);
  assert.doesNotMatch(initial.tree, /25°C/);
  const expanded = await run(edit(project, "main.jsx", "upcoming.slice(0, 2)", "upcoming.slice(0, 3)"));
  assert.match(expanded.tree, /25°C/);
  const rain = await run({ ...project, fixtures: tutorialScenario("weather-forecast", "rain") });
  assert.match(rain.tree, /Rain · 14°C/);
  assert.match(rain.tree, /cloud\.rain\.fill/);
  const offline = await run({ ...project, fixtures: tutorialScenario("weather-forecast", "offline") });
  assert.match(offline.tree, /Forecast unavailable/);
  assert.doesNotMatch(offline.tree, /22°C|14°C/);
});

test("the Calendar exercise distinguishes undeclared, authorized, empty, and denied", async () => {
  const project = createTutorialProject("calendar-agenda");
  const initial = await run(project);
  assert.match(initial.tree, /Declare Calendar access/);
  assert.doesNotMatch(initial.tree, /Design review/);

  const changedJS = edit(project, "main.jsx", "Declare Calendar access", "Design review");
  assert.equal(tutorialSourceChanged("calendar-agenda", changedJS), false);
  const invalidManifest = edit(project, "widget.json", '"permissions": []', '"permissions": "calendar"');
  assert.equal(tutorialSourceChanged("calendar-agenda", invalidManifest), false);

  const authorized = edit(project, "widget.json", '"permissions": []', '"permissions": ["calendar"]');
  assert.equal(tutorialSourceChanged("calendar-agenda", authorized), true);
  for (const [scenario, message] of [["granted", /Design review/], ["empty", /No events today/], ["denied", /Connect Calendar/]] as const) {
    const preview = await run({ ...authorized, fixtures: tutorialScenario("calendar-agenda", scenario) });
    assert.match(preview.tree, message);
    if (scenario !== "granted") assert.doesNotMatch(preview.tree, /Design review/);
  }
});
