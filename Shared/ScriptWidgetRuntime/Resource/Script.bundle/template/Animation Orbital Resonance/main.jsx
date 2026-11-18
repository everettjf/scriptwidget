// Three coupled orbits whose periods form a 2:3:5 resonance.
// Each orbit is a ring with a moon on it, turned by a "clockCustom" animation.
// Try changing the periods in the three orbit(...) calls.
//
// orbit(size, period, color, moonSize, rotation): `size` is the ring's diameter in points,
// `period` the seconds for half a turn (a negative number turns the other way) and
// `rotation` the starting angle in degrees.
const orbit = (size, period, color, moonSize, rotation) => (
  <zstack frame={`${size},${size}`} animation={`clockCustom,${period}`} rotation={rotation}>
    {/* The thin ring: `stroke` draws a 1-point outline with no fill. */}
    <circle frame={`${size - 2},${size - 2}`} color="#273451" stroke="1" />
    {/* The moon sits at the top of a box as large as the ring, so it travels along the ring. */}
    <vstack frame={`${size},${size}`}>
      <circle frame={`${moonSize},${moonSize}`} color={color} />
      <spacer />
    </vstack>
  </zstack>
);

$render(
  <zstack frame="max" background="#070b18">
    <circle frame="136,136" color="#10182b" />
    {/* Half-turn times of 30, 18 and 12 seconds: the ratio 5:3:2. */}
    {orbit(126, 30, "#67e8f9", 10, 18)}
    {orbit(98, -18, "#c084fc", 13, 138)}
    {orbit(70, 12, "#fbbf24", 9, 258)}
    {/* The sun in the middle. */}
    <circle frame="30,30" color="#fef3c7" />
    <circle frame="16,16" color="#f59e0b" />
    <vstack frame="max" alignment="leading" padding="12">
      <text font="caption" weight="bold" color="#a5f3fc">
        {"ORBITAL  2:3:5"}
      </text>
      <spacer />
    </vstack>
  </zstack>,
);
