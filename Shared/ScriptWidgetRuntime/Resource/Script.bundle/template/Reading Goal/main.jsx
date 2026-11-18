// widget-param: books read,goal (optional), e.g. 7,12
//
// This template shows two numbers from the widget parameter and a progress bar.
// Try changing the default "7,12" or the texts.

// $getenv("widget-param") is the parameter text set for this widget; "7,12" becomes [7, 12].
const values = ($getenv("widget-param") || "7,12").split(",").map(Number);
// A missing or non-numeric part falls back to 0 books read and a goal of 12.
const read = values[0] || 0;
const goal = values[1] || 12;
// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
if ($getenv("widget-size") === "small") {
  // Small: books read out of the goal.
  // frame="max" fills the widget; padding is the space around the content, in points.
  $render(
    <vstack frame="max" alignment="leading" spacing="6" padding="14" background="#b45309">
      <hstack spacing="6">
        <icon systemName="books.vertical.fill" size="18" color="#fef3c7" />
        <text font="caption" color="#fffbeb">
          READING
        </text>
      </hstack>
      <vstack frame="max,leading" alignment="leading" spacing="2">
        <text font="title" weight="bold" color="white">
          {read} of {goal}
        </text>
        <text font="caption" color="#fef3c7">
          books · {Math.max(0, goal - read)} to go
        </text>
      </vstack>
      {/* <progress> draws a bar filled to value out of total. */}
      <progress value={read} total={goal} color="#fcd34d" />
    </vstack>,
  );
} else {
  // Medium and larger: the same information with longer texts.
  $render(
    <vstack frame="max" alignment="leading" spacing="9" padding="14" background="#b45309">
      <hstack frame="max">
        <icon systemName="books.vertical.fill" size="22" color="#fef3c7" />
        <spacer />
        <text font="caption" color="#fffbeb">
          READING GOAL
        </text>
      </hstack>
      <text font="title" weight="bold" color="white">
        {read} of {goal} books
      </text>
      <progress value={read} total={goal} color="#fcd34d" />
      <text font="caption" color="#fef3c7">
        {Math.max(0, goal - read)} to go · keep turning pages
      </text>
    </vstack>,
  );
}
