// Animation Spirograph
// Three dots on circles that turn inside a larger turning circle, some one way and some
// the other. Try changing the periods or adding a fourth satellite.
//
// satellite(radius, period, color, size, phase): a dot at the top of a box `radius` points
// wide. "clockCustom" turns the box half a turn every `period` seconds (a negative number
// turns the other way). `phase` is the starting angle in degrees.
const satellite = (radius, period, color, size, phase) => (
  <zstack frame={`${radius},${radius}`} animation={`clockCustom,${period}`} rotation={phase}>
    <vstack frame={`${radius},${radius}`}>
      <circle frame={`${size},${size}`} color={color} />
      <spacer />
    </vstack>
  </zstack>
);

// Counter-rotating epicycles approximate a hypotrochoid mechanism.
$render(
  <zstack frame="max" background="#071a17">
    {/* Two guide circles. `stroke` draws a 1-point outline with no fill. */}
    <circle frame="132,132" color="#134e4a" stroke="1" />
    <circle frame="102,102" color="#115e59" stroke="1" />
    {/* The outer stack turns as well, so each dot's own turn is added to this one. */}
    <zstack frame="126,126" animation="clockCustom,24">
      {satellite(112, -9, "#5eead4", 11, 0)}
      {satellite(82, 15, "#f472b6", 9, 120)}
      {satellite(54, -6, "#facc15", 7, 240)}
    </zstack>
    {/* The fixed center. */}
    <circle frame="14,14" color="#ecfeff" />
    <vstack frame="max" alignment="leading" padding="12">
      <text font="caption" weight="bold" color="#99f6e4">
        HYPOTROCHOID
      </text>
      <spacer />
      <text font="caption2" color="#5eead4">
        24 : −9 : 15 : −6
      </text>
    </vstack>
  </zstack>,
);
