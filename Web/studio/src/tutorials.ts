import { newManifest } from "../../preview-engine/src/package/index.js";
import type { WidgetManifest } from "../../preview-engine/src/types.js";
import { permissionScenario, setResponse } from "./mockData.ts";
import { createProject, packageReport, type Project } from "./project.ts";

export type TutorialId = "hello-world" | "event-countdown" | "interactive-todo" | "weather-forecast" | "calendar-agenda";

export interface TutorialStep {
  id: string;
  title: string;
  instruction: string;
  hint?: string;
  code?: string;
  file?: "main.jsx" | "widget.json";
  control?:
    | { kind: "action"; actionID: string; label: string }
    | { kind: "scenario"; scenarioID: string; label: string }
    | { kind: "family"; family: "small" | "medium"; label: string };
  expected: {
    text: string;
    family?: "small" | "medium";
    changedSource?: boolean;
    boundAction?: string;
    scenarioID?: string;
    actionID?: string;
    reload?: boolean;
  };
}

export interface TutorialLesson {
  id: TutorialId;
  version: number;
  title: string;
  duration: string;
  description: string;
  takeaway: string;
  steps: TutorialStep[];
  deviceNote?: string;
}

export const tutorials: readonly TutorialLesson[] = [
  {
    id: "hello-world", version: 1, title: "Hello World", duration: "2 min",
    description: "Write your first line of JSX and see it on a widget.",
    takeaway: "You used $render to turn a stack of JSX elements into a widget.",
    steps: [
      {
        id: "change-text", title: "Change the greeting", file: "main.jsx",
        instruction: "Replace the first line in main.jsx with the line below. See how the value inside the braces changes the greeting in the preview.",
        code: 'const name = "Studio";',
        hint: "Keep the quotation marks around Studio. The editor refreshes the preview as you type.",
        expected: { text: "Hello, Studio!", changedSource: true },
      },
      {
        id: "add-caption", title: "Add another line", file: "main.jsx",
        instruction: "Add a second text element just above </vstack>. A vertical stack places it beneath the greeting.",
        code: '<text font="caption" color="#134e4a">Built in JavaScript</text>',
        hint: "Keep both text elements inside the same stack. After this step you can personalize both lines.",
        expected: { text: "Built in JavaScript", changedSource: true },
      },
    ],
  },
  {
    id: "event-countdown", version: 1, title: "Event Countdown", duration: "4 min",
    description: "Count down to an event and make the widget fit two sizes.",
    takeaway: "The same event and date can drive different layouts for different widget sizes.",
    steps: [
      {
        id: "name-event", title: "Name the event", file: "main.jsx",
        instruction: "Replace the eventName line with the example below. The title and countdown share the same widget.",
        code: 'const eventName = "Launch day";',
        hint: "Use this title for the exercise. You can name your own event when you finish.",
        expected: { text: "Launch day", changedSource: true },
      },
      {
        id: "change-date", title: "Move it one week later", file: "main.jsx",
        instruction: "Replace the targetDate line. In the Small preview, check how the displayed date and number of days change.",
        code: 'const targetDate = "2030-06-22";',
        hint: "Use YYYY-MM-DD. The counter compares calendar dates, so a daylight-saving change does not shift it by a day.",
        control: { kind: "family", family: "small", label: "Preview Small" },
        expected: { text: "2030-06-22", family: "small", changedSource: true },
      },
      {
        id: "compare-sizes", title: "Compare Small and Medium",
        instruction: "Switch to Medium. The date and count use the same values, with more horizontal space for the count.",
        control: { kind: "family", family: "medium", label: "Preview Medium" },
        expected: { text: "2030-06-22", family: "medium" },
      },
    ],
  },
  {
    id: "interactive-todo", version: 1, title: "Interactive To-Do", duration: "7 min",
    description: "Wire up a widget button and keep a task checked after reload.",
    takeaway: "The button calls a declared action. The action saves state, and rendering reads it back.",
    deviceNote: "The browser saves this lesson’s simulated storage with its draft. When installed, $storage belongs to the widget package on that device. The iCloud exercise uses a separate, explicitly connected store.",
    steps: [
      {
        id: "bind-button", title: "Connect a button to an action", file: "main.jsx",
        instruction: "Replace the firstTaskAction line. This wraps the first row in a button and binds it to toggleOne, the action declared in widget.json.",
        code: 'const firstTaskAction = "toggleOne";',
        hint: "The actionID on <button> must match the manifest action ID. Only the first task is interactive in this exercise.",
        expected: { text: "0/5", changedSource: true, boundAction: "toggleOne" },
      },
      {
        id: "check-task", title: "Check off the first task",
        instruction: "Run the button action against browser sample storage. It saves the checked value and the preview reads it back.",
        control: { kind: "action", actionID: "toggleOne", label: "Check off first task" },
        expected: { text: "1/5", actionID: "toggleOne", boundAction: "toggleOne" },
      },
      {
        id: "reload-list", title: "Check that it stayed saved",
        instruction: "Reload this browser tab. The tutorial resumes at this step and checks the saved preview data.",
        hint: "Wait for Saved in this browser before reloading. The action updates browser sample storage for this project.",
        expected: { text: "1/5", reload: true, boundAction: "toggleOne" },
      },
      {
        id: "undo-task", title: "Uncheck the task",
        instruction: "Run the same action again. The handler reads the saved value, writes the opposite value, and the count returns to zero.",
        control: { kind: "action", actionID: "toggleOne", label: "Uncheck first task" },
        expected: { text: "0/5", actionID: "toggleOne", boundAction: "toggleOne" },
      },
    ],
  },
  {
    id: "weather-forecast", version: 1, title: "Weather Forecast", duration: "6 min",
    description: "Display hourly temperatures and handle an unavailable forecast.",
    takeaway: "The same script can render a successful forecast or a clear message when the request fails.",
    deviceNote: "Studio uses sample forecasts. For live forecasts on a supported device, enable this widget’s Weather access in ScriptWidget. The code requests a fixed place, so it does not need device location.",
    steps: [
      {
        id: "sunny", title: "Read a forecast",
        instruction: "Load the sunny sample. The script awaits $weather.forecast(), then uses the first forecast hour for the headline and the next hours for their temperatures.",
        control: { kind: "scenario", scenarioID: "sunny", label: "Show sunny forecast" },
        expected: { text: "Sunny · 22°C", scenarioID: "sunny" },
      },
      {
        id: "show-hour", title: "Show one more forecast hour", file: "main.jsx",
        instruction: "Change the 2 in upcoming.slice(0, 2) to 3. The preview should add a 25°C row after the first two forecast hours.",
        code: "upcoming.slice(0, 3)",
        hint: "Array.slice keeps the first items. Array.map turns each one into a line of JSX.",
        expected: { text: "25°C", changedSource: true },
      },
      {
        id: "rain", title: "Try a different forecast",
        instruction: "Load the rainy sample. The same JSX renders a different icon and temperature because the response values changed.",
        control: { kind: "scenario", scenarioID: "rain", label: "Show rainy forecast" },
        expected: { text: "Rain · 14°C", scenarioID: "rain" },
      },
      {
        id: "offline", title: "Handle a failed request",
        instruction: "Simulate a network failure. The catch block replaces the forecast with a short message.",
        control: { kind: "scenario", scenarioID: "offline", label: "Simulate network failure" },
        expected: { text: "Forecast unavailable", scenarioID: "offline" },
      },
    ],
  },
  {
    id: "calendar-agenda", version: 1, title: "Calendar Agenda", duration: "7 min",
    description: "Show today’s events and handle empty and denied Calendar access.",
    takeaway: "The manifest declares what a widget needs. The host controls what it can actually read.",
    deviceNote: "Studio uses sample events. To read your own events on a supported device, connect Calendar in ScriptWidget settings and choose which calendars your widgets can read.",
    steps: [
      {
        id: "declare-access", title: "Declare Calendar access", file: "widget.json",
        instruction: "Open widget.json and replace the permissions line. When the package declares calendar, the authorized sample can show its first event.",
        code: '"permissions": ["calendar"],',
        hint: "The declaration tells ScriptWidget what the widget needs. On a device, access also depends on your Calendar settings.",
        expected: { text: "Design review", changedSource: true },
      },
      {
        id: "no-events", title: "Show an empty day",
        instruction: "Load an authorized Calendar with no events. An empty list should give the reader a clear message.",
        control: { kind: "scenario", scenarioID: "empty", label: "Show an empty day" },
        expected: { text: "No events today", scenarioID: "empty" },
      },
      {
        id: "denied", title: "Simulate denied access",
        instruction: "Try a denied response. The widget asks you to connect Calendar instead of claiming the day is empty.",
        control: { kind: "scenario", scenarioID: "denied", label: "Simulate denied access" },
        expected: { text: "Connect Calendar", scenarioID: "denied" },
      },
      {
        id: "restore", title: "Restore the event list",
        instruction: "Return to the authorized sample and check that the event list comes back.",
        control: { kind: "scenario", scenarioID: "granted", label: "Show sample events" },
        expected: { text: "Design review", scenarioID: "granted" },
      },
    ],
  },
];

const sources: Record<TutorialId, string> = {
  "hello-world": `const name = "world";

// $render receives one JSX element. A vertical stack can hold several children.
$render(
  <vstack frame="max" spacing="6" padding="16" background="#ecfdf5">
    <text font="headline" color="#134e4a">
      MY FIRST WIDGET
    </text>
    <text font="title" color="#0f766e">
      Hello, {name}!
    </text>
  </vstack>,
);
`,

  "event-countdown": `const eventName = "My event";
const targetDate = "2030-06-15";

// Compare days on the calendar, independent of the length of any single day.
const now = new Date($getenv("timeline-date") || Date.now());
const today = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
const target = new Date(targetDate + "T00:00:00Z");
const days = (target.getTime() - today) / 86400000;
const validDate = Number.isFinite(days) && target.toISOString().slice(0, 10) === targetDate;
const count = !validDate
  ? "Use YYYY-MM-DD"
  : days === 0
    ? "Today"
    : Math.abs(days) + (Math.abs(days) === 1 ? " day" : " days") + (days > 0 ? " left" : " ago");

const event = (
  <vstack alignment="leading" spacing="4">
    <text font="caption2" color="#3730a3">
      COUNTDOWN
    </text>
    <text font="headline" color="#1e1b4b">
      {eventName}
    </text>
    <text font="caption" color="#3730a3">
      {targetDate}
    </text>
  </vstack>
);
const counter = (
  <text font="headline" color="#4338ca">
    {count}
  </text>
);

// Reuse the same elements and change the arrangement to fit each size.
if ($getenv("widget-size") === "small") {
  $render(
    <vstack frame="max" alignment="leading" spacing="10" padding="14" background="#eef2ff">
      {event}
      {counter}
    </vstack>,
  );
} else {
  $render(
    <hstack frame="max" spacing="12" padding="16" background="#eef2ff">
      {event}
      <spacer />
      {counter}
    </hstack>,
  );
}
`,

  "interactive-todo": `const tasks = [
  "Write an outline",
  "Review the draft",
  "Send feedback",
  "Take a break",
  "Plan tomorrow",
];
const firstTaskAction = "";
const key = "tutorial.todo.first-task";

// This function runs only when the matching action is invoked.
function toggleOne() {
  for (let attempt = 0; attempt < 4; attempt++) {
    const previous = $storage.getString(key);
    const next = previous === "checked" ? "unchecked" : "checked";
    if ($storage.compareAndSetString(key, previous, next)) {
      $render(<text>Task saved</text>);
      return;
    }
  }
  throw new Error("Could not save the task. Try again.");
}

const size = $getenv("widget-size");
if (size !== "action" && size !== "function") {
  // Rendering reads saved progress. Only the action changes it.
  const done = $storage.getString(key) === "checked";
  const firstRow = (
    <hstack spacing="6">
      <icon systemName={done ? "checkmark.square.fill" : "square"} size="13" color="#047857" />
      <text font="caption" color="#064e3b">
        {tasks[0]}
      </text>
    </hstack>
  );
  const visibleCount = size === "small" ? 3 : tasks.length;

  $render(
    <vstack frame="max" alignment="leading" spacing="5" padding="12" background="#ecfdf5">
      <hstack>
        <text font="headline" color="#064e3b">
          To-do
        </text>
        <spacer />
        <text font="caption" color="#047857">
          {(done ? 1 : 0) + "/" + tasks.length}
        </text>
      </hstack>
      {firstTaskAction ? <button actionID={firstTaskAction}>{firstRow}</button> : firstRow}
      {tasks.slice(1, visibleCount).map((task) => (
        <text font="caption" color="#065f46">
          {task}
        </text>
      ))}
    </vstack>,
  );
}
`,

  "weather-forecast": `// Fetch a forecast for a fixed place. Widget permissions are in widget.json.
const place = { latitude: 37.33, longitude: -122.01, hours: 6 };

function appearance(condition) {
  if (condition?.includes("rain")) return { title: "Rain", icon: "cloud.rain.fill" };
  if (condition?.includes("snow")) return { title: "Snow", icon: "cloud.snow.fill" };
  if (condition?.startsWith("clearsky")) return { title: "Sunny", icon: "sun.max.fill" };
  if (condition?.includes("cloud")) return { title: "Cloudy", icon: "cloud.fill" };
  return { title: "Forecast", icon: "cloud" };
}

try {
  const forecast = await $weather.forecast(place);
  const [current, ...upcoming] = forecast.hours;
  if (!current) throw new Error("No forecast hours are available.");
  const { title, icon } = appearance(current.condition);
  const headline = title + " · " + Math.round(current.temperatureC) + "°C";

  $render(
    <vstack frame="max" alignment="leading" spacing="5" padding="12" background="#eff6ff">
      <text font="caption" color="#1e40af">
        CUPERTINO FORECAST
      </text>
      <hstack spacing="6">
        <icon systemName={icon} size="16" color="#1d4ed8" />
        <text font="headline" color="#172554">
          {headline}
        </text>
      </hstack>
      {upcoming.slice(0, 2).map((hour) => {
        const time = new Date(hour.time).toLocaleTimeString([], {
          hour: "numeric",
          minute: "2-digit",
        });
        return (
          <text font="caption" color="#1e40af">
            {time + " · " + Math.round(hour.temperatureC) + "°C"}
          </text>
        );
      })}
      {forecast.isStale && (
        <text font="caption2" color="#1e40af">
          Cached forecast
        </text>
      )}
      <link url={forecast.attribution.url}>
        <text font="caption2" color="#1e40af">
          {forecast.attribution.text}
        </text>
      </link>
    </vstack>,
  );
} catch (error) {
  console.log(String(error));
  $render(
    <vstack frame="max" spacing="6" padding="12" background="#eff6ff">
      <icon systemName="cloud" size="22" color="#1d4ed8" />
      <text font="headline" color="#172554">
        Forecast unavailable
      </text>
    </vstack>,
  );
}
`,

  "calendar-agenda": `// Calendar is a read-only data source in this widget. The app manages access.
let events = [];
let message = "";

if (!$calendar.isAvailable()) {
  message = "Calendar unavailable";
} else if ($calendar.authorizationStatus() === "undeclared") {
  message = "Declare Calendar access";
} else if ($calendar.authorizationStatus() !== "authorized") {
  message = "Connect Calendar";
} else {
  try {
    // The default date range is today. Limit the list to fit the widget.
    const result = await $calendar.events({ limit: 2, maxAgeSeconds: 60 });
    events = result.items;
    if (!events.length) message = "No events today";
  } catch (error) {
    message = "Check Calendar settings";
  }
}

$render(
  <vstack frame="max" alignment="leading" spacing="7" padding="14" background="#faf5ff">
    <hstack spacing="5">
      <icon systemName="calendar" size="14" color="#7e22ce" />
      <text font="caption" color="#6b21a8">
        TODAY'S AGENDA
      </text>
    </hstack>
    {events.map((event) => {
      const time = event.allDay
        ? "All day"
        : new Date(event.start).toLocaleTimeString([], {
            hour: "numeric",
            minute: "2-digit",
          });
      return (
        <vstack alignment="leading" spacing="1">
          <text font="headline" color="#3b0764">
            {event.title}
          </text>
          <text font="caption2" color="#6b21a8">
            {time}
          </text>
        </vstack>
      );
    })}
    {message && (
      <text font="headline" color="#3b0764">
        {message}
      </text>
    )}
  </vstack>,
);
`,
};

const manifests: Partial<Record<TutorialId, Partial<WidgetManifest>>> = {
  "event-countdown": { timeline: { dailyTimes: ["00:00"] } },
  "interactive-todo": {
    permissions: ["storage"], minimumRuntimeVersion: "1.3",
    actions: [{ id: "toggleOne", title: "Toggle the first task", systemImage: "checkmark.square", function: "toggleOne" }],
  },
  "weather-forecast": { permissions: ["weather", "network"], networkDomains: ["api.met.no"], minimumRuntimeVersion: "1.6" },
  "calendar-agenda": { minimumRuntimeVersion: "1.3" },
};

export function createTutorialProject(id: TutorialId): Project {
  const lesson = tutorials.find((item) => item.id === id)!;
  const manifest: WidgetManifest = {
    ...newManifest(lesson.title, { description: lesson.description }),
    supportedFamilies: ["systemSmall", "systemMedium"],
    ...manifests[id],
  };
  const project = createProject(lesson.title, {
    "widget.json": JSON.stringify(manifest, null, 2) + "\n",
    "main.jsx": sources[id],
  });
  const scenario = id === "weather-forecast" ? "sunny" : id === "calendar-agenda" ? "granted" : null;
  return { ...project, fixtures: scenario ? tutorialScenario(id, scenario) : "{}" };
}

export function tutorialSourceChanged(id: TutorialId, project: Project): boolean {
  if (id === "calendar-agenda") {
    const report = packageReport(project);
    return report.valid && report.manifest?.permissions.includes("calendar") === true;
  }
  const source = project.files["main.jsx"];
  return typeof source === "string" && source !== sources[id];
}

/** These scenario responses belong to the draft, separately from its exportable files. */
export function tutorialScenario(id: TutorialId, scenarioID: string): string {
  if (id === "weather-forecast" && ["sunny", "rain", "offline"].includes(scenarioID)) {
    const fixtures = JSON.stringify({ systemAccess: { permissions: ["weather"] } });
    const api = "$weather.forecast";
    if (scenarioID === "offline") return setResponse(fixtures, api, { error: "Forecast request failed" });

    const start = new Date();
    start.setMinutes(0, 0, 0);
    const rain = scenarioID === "rain";
    return setResponse(fixtures, api, { value: {
      provider: "met.no", latitude: 37.33, longitude: -122.01,
      attribution: { text: "Weather data: MET Norway", url: "https://www.met.no/en" },
      fetchedAt: start.toISOString(), isStale: false,
      hours: [0, 1, 2, 3].map((offset) => ({
        time: new Date(start.getTime() + offset * 3600000).toISOString(),
        temperatureC: (rain ? 14 : 22) + offset,
        windMetersPerSecond: 2, precipitationMM: rain ? 1 : 0,
        condition: rain ? "rain" : "clearsky_day",
      })),
    } });
  }

  if (id === "calendar-agenda" && (scenarioID === "granted" || scenarioID === "empty" || scenarioID === "denied")) {
    const fixtures = permissionScenario("{}", "calendar", scenarioID);
    if (scenarioID !== "granted") return fixtures;

    const day = new Date();
    const event = (id: string, title: string, hour: number) => {
      const start = new Date(day);
      start.setHours(hour, 0, 0, 0);
      return {
        id, calendarID: "sample.personal", title, start: start.toISOString(),
        end: new Date(start.getTime() + 1800000).toISOString(), allDay: false,
      };
    };
    return setResponse(fixtures, "$calendar.events", { value: {
      status: "ready", source: "system", fetchedAt: day.toISOString(), stale: false, truncated: false,
      items: [event("design-review", "Design review", 10), event("project-planning", "Project planning", 14)],
    } });
  }

  throw new Error("This tutorial sample is unavailable.");
}
