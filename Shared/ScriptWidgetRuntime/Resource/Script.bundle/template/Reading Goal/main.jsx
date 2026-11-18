// widget-param: books read,goal (optional), e.g. 7,12
const values = ($getenv("widget-param") || "7,12").split(",").map(Number);
const read = values[0] || 0;
const goal = values[1] || 12;
if ($getenv("widget-size") === "small") {
  // Small: books read out of the goal.
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
      <progress value={read} total={goal} color="#fcd34d" />
    </vstack>,
  );
} else {
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
