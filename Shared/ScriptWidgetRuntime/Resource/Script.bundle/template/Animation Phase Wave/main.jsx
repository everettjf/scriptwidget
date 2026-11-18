// Animation Phase Wave
// Nine dots that turn at slightly different speeds, so they drift in and out of step.
// Try changing the step between the phases, or the 0.17 that sets the speed difference.
//
// The starting angle of each dot in degrees: nine equal steps of 40.
const phases = [0, 40, 80, 120, 160, 200, 240, 280, 320];
// One color for each dot.
const colors = [
  "#38bdf8",
  "#22d3ee",
  "#2dd4bf",
  "#a3e635",
  "#fde047",
  "#fb923c",
  "#fb7185",
  "#c084fc",
  "#818cf8",
];

// One dot at the top of a tall box, with a small gray dot at the bottom. The box starts
// turned by `phase` degrees. "clockCustom,n" turns it half a turn every n seconds; each
// box takes 0.17 seconds longer than the one before.
const oscillator = (phase, index) => (
  <zstack frame="24,92" animation={`clockCustom,${12 + index * 0.17}`} rotation={phase}>
    <vstack frame="24,92">
      <circle frame="12,12" color={colors[index]} />
      <spacer />
      <circle frame="4,4" color="#334155" />
    </vstack>
  </zstack>
);

// A discretized traveling wave: equal angular steps with a slight frequency gradient.
$render(
  <zstack frame="max" background="#050b16">
    <circle frame="116,116" color="#172033" stroke="1" />
    {/* Negative spacing makes the nine boxes overlap. */}
    <hstack frame="max" spacing="-10">
      {phases.map((phase, index) => oscillator(phase, index))}
    </hstack>
    <circle frame="11,11" color="#f8fafc" />
    <vstack frame="max" alignment="leading" padding="12">
      <text font="caption" weight="bold" color="#bae6fd">
        {"PHASE WAVE  Δφ=40°"}
      </text>
      <spacer />
    </vstack>
  </zstack>,
);
