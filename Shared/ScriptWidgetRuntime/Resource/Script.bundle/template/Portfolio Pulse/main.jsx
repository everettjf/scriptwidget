//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Portfolio Pulse: total value, a 30-day sparkline, and holdings.
// Sample numbers keep it offline; replace them with your own data.
//

// $getenv("widget-size") is the size being drawn: "small", "medium", "large", …
const size = $getenv("widget-size");
// Sample data: 30 daily values for the sparkline, oldest first.
const history = [
  96.2, 97.1, 96.8, 98.4, 99.0, 98.1, 99.6, 100.4, 101.2, 100.6, 101.9, 102.4, 101.8, 103.1, 104.0,
  103.2, 104.8, 105.5, 104.9, 106.2, 107.0, 106.4, 107.9, 108.6, 108.1, 109.4, 110.2, 109.6, 111.0,
  112.4,
];
// Each holding: [symbol, name, price, today's change in percent].
const holdings = [
  ["AAPL", "Apple", 231.4, 1.24],
  ["MSFT", "Microsoft", 421.8, 0.62],
  ["NVDA", "NVIDIA", 132.6, -1.85],
  ["AMZN", "Amazon", 186.3, 0.41],
  ["TSLA", "Tesla", 198.1, -2.37],
];
// The total value in dollars and today's change in percent.
const value = 48261.37;
const change = 1.27;
// Colors for a rise and a fall.
const up = "#30D158";
const down = "#FF453A";
// money(48261.37) gives "$48,261.37"; signed(1.27) gives "+1.27%".
const money = (amount) =>
  `$${amount.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const signed = (percent) => `${percent >= 0 ? "+" : ""}${percent.toFixed(2)}%`;

// The sparkline: an area chart without axes. data is a JSON string of { label, value }
// points. 90 is subtracted so that the small ups and downs use the whole height.
const Spark = ({ height }) => (
  <chart
    type="area"
    hideXAxis="true"
    hideYAxis="true"
    color="#30D158"
    opacity="0.75"
    frame={`max,${height}`}
    data={JSON.stringify(
      history.map((point, index) => ({
        label: String(index),
        value: Math.round((point - 90) * 10) / 10,
      })),
    )}
  />
);
// The total, with today's change in green or red.
const Total = ({ font }) => (
  <vstack alignment="leading" spacing="2">
    <text font="caption" fontWeight="semibold" color="#8E8E93">
      PORTFOLIO
    </text>
    <text font={font} fontWeight="bold" color="white">
      {money(value)}
    </text>
    <hstack spacing="4">
      <icon
        systemName={change >= 0 ? "arrow.up.right" : "arrow.down.right"}
        size="11"
        color={change >= 0 ? up : down}
      />
      <text font="caption" fontWeight="semibold" color={change >= 0 ? up : down}>
        {signed(change)} today
      </text>
    </hstack>
  </vstack>
);
// One row of the holdings list; item is one entry of `holdings`.
const Holding = ({ item }) => (
  <hstack spacing="8">
    <vstack alignment="leading" spacing="0">
      <text font="subheadline" fontWeight="semibold" color="white">
        {item[0]}
      </text>
      <text font="caption2" color="#8E8E93">
        {item[1]}
      </text>
    </vstack>
    <spacer />
    <text font="subheadline" color="white">
      {item[2].toFixed(2)}
    </text>
    <text
      font="caption"
      fontWeight="semibold"
      color="white"
      background={item[3] >= 0 ? up : down}
      corner="5"
      padding="horizontal,6"
      frame="64,22"
    >
      {signed(item[3])}
    </text>
  </hstack>
);

// Choose a layout for the widget size. The "accessory" sizes are Lock Screen widgets
// (iPhone and iPad only).
if (size === "accessoryCircular") {
  $render(
    <vstack spacing="0">
      <icon systemName="chart.line.uptrend.xyaxis" size="14" />
      <text font="caption" fontWeight="bold">
        {signed(change)}
      </text>
    </vstack>,
  );
} else if (size === "accessoryRectangular") {
  $render(
    <vstack alignment="leading" spacing="1" frame="max,leading">
      <text font="headline">{money(value)}</text>
      <text font="caption">{signed(change)} today</text>
      <text font="caption">
        {holdings[0][0]} {signed(holdings[0][3])} · {holdings[2][0]} {signed(holdings[2][3])}
      </text>
    </vstack>,
  );
} else if (size === "accessoryInline") {
  $render(
    <text>
      Portfolio {signed(change)} · {money(value)}
    </text>,
  );
} else if (size === "small") {
  // Small: the total above the sparkline. padding is the space around the content.
  $render(
    <vstack alignment="leading" spacing="6" padding="14" background="#0B0B0F">
      <Total font="title3" />
      <spacer />
      <Spark height={46} />
    </vstack>,
  );
} else if (size === "medium") {
  // Medium: total and sparkline on the left, three holdings on the right.
  $render(
    <hstack spacing="16" padding="14" background="#0B0B0F">
      <vstack alignment="leading" spacing="6" frame="max,leading">
        <Total font="title2" />
        <spacer />
        <Spark height={48} />
      </vstack>
      <vstack spacing="8" frame="118">
        {holdings.slice(0, 3).map((item) => (
          <hstack>
            <text font="subheadline" fontWeight="semibold" color="white">
              {item[0]}
            </text>
            <spacer />
            <text
              font="caption"
              fontWeight="semibold"
              color="white"
              background={item[3] >= 0 ? up : down}
              corner="5"
              frame="62,22"
            >
              {signed(item[3])}
            </text>
          </hstack>
        ))}
      </vstack>
    </hstack>,
  );
} else if (size === "extraLarge") {
  // Extra large: a taller chart and all five holdings.
  $render(
    <hstack spacing="32" padding="24" background="#0B0B0F">
      <vstack alignment="leading" spacing="16" frame="max,leading">
        <Total font="largeTitle" />
        <Spark height={150} />
      </vstack>
      <vstack spacing="10" frame="280">
        {holdings.map((item) => (
          <Holding item={item} />
        ))}
      </vstack>
    </hstack>,
  );
} else {
  // Large: total, sparkline and four holdings.
  $render(
    <vstack alignment="leading" spacing="12" padding="16" background="#0B0B0F">
      <Total font="title" />
      <Spark height={70} />
      <vstack spacing="8">
        {holdings.slice(0, 4).map((item) => (
          <Holding item={item} />
        ))}
      </vstack>
      <spacer />
    </vstack>,
  );
}
