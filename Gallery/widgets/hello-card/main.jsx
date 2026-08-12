// ScriptWidget Gallery: Hello Card
const family = $getenv("widget-size");

function refreshCard() {
  console.log(`Hello Card refreshed from ${$getenv("action-source")}`);
}

$render(
  <vstack background="#17213A" padding="16" corner="18" spacing="8">
    <text font="caption" color="#9CB4FF">SCRIPTWIDGET GALLERY</text>
    <text font="title" fontWeight="bold" color="#FFFFFF">Hello from GitHub</text>
    <text font="caption" color="#BEC8E5">Edit me in Studio · {family}</text>
    <button actionID="refresh">
      <label title="Refresh" systemName="arrow.clockwise" />
    </button>
  </vstack>
);
