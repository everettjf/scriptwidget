// Three coupled orbits whose periods form a 2:3:5 resonance.
const orbit = (size, period, color, moonSize, rotation) => (
  <zstack frame={`${size},${size}`} animation={`clockCustom,${period}`} rotation={rotation}>
    <circle frame={`${size - 2},${size - 2}`} color="#273451" stroke="1" />
    <vstack frame={`${size},${size}`}>
      <circle frame={`${moonSize},${moonSize}`} color={color} />
      <spacer />
    </vstack>
  </zstack>
);

$render(
  <zstack frame="max" background="#070b18">
    <circle frame="136,136" color="#10182b" />
    {orbit(126, 30, "#67e8f9", 10, 18)}
    {orbit(98, -18, "#c084fc", 13, 138)}
    {orbit(70, 12, "#fbbf24", 9, 258)}
    <circle frame="30,30" color="#fef3c7" />
    <circle frame="16,16" color="#f59e0b" />
    <vstack frame="max" alignment="leading" padding="12">
      <text font="caption" weight="bold" color="#a5f3fc">ORBITAL  2:3:5</text>
      <spacer />
    </vstack>
  </zstack>
);
