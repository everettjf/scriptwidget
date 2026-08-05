const horizontal = { type: "swing", duration: 7, direction: "horizontal", distance: 88 };
const vertical = { type: "swing", duration: 11, direction: "vertical", distance: 58 };

// Orthogonal oscillators with coprime periods trace a slowly repeating path.
$render(
  <zstack frame="max" background="#09051a">
    <ellipse frame="132,78" color="#312e81" stroke="1" rotation={28} />
    <ellipse frame="132,78" color="#4c1d95" stroke="1" rotation={-28} />
    <zstack frame="122,122" animation={$animation(horizontal)}>
      <zstack frame="92,92" animation={$animation(vertical)}>
        <circle frame="24,24" color="#f0abfc" />
        <circle frame="10,10" color="#ffffff" />
      </zstack>
    </zstack>
    <circle frame="5,5" color="#67e8f9" />
    <vstack frame="max" alignment="leading" padding="12">
      <text font="caption" weight="bold" color="#e9d5ff">LISSAJOUS  7×11</text>
      <spacer />
      <text font="caption2" color="#a78bfa">orthogonal phase space</text>
    </vstack>
  </zstack>
);
