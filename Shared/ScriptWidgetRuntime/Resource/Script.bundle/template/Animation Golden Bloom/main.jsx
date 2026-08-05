const goldenAngle = 137.507764;
const petals = Array.from({ length: 13 }, (_, index) => index);
const seeds = Array.from({ length: 8 }, (_, index) => index);

const petal = (index) => (
  <vstack frame="34,118" rotation={index * goldenAngle}>
    <ellipse frame="15,38" color={index % 2 === 0 ? "#f9a8d4" : "#c4b5fd"} />
    <spacer />
  </vstack>
);

const seed = (index) => (
  <vstack frame="16,64" rotation={index * goldenAngle}>
    <circle frame="7,7" color="#fde68a" />
    <spacer />
  </vstack>
);

// Fermat phyllotaxis: consecutive elements differ by the golden angle.
$render(
  <zstack frame="max" background="#1b1026">
    <zstack frame="126,126" animation="clockCustom,34">
      {petals.map(petal)}
    </zstack>
    <zstack frame="76,76" animation="clockCustom,-21">
      {seeds.map(seed)}
    </zstack>
    <circle frame="28,28" color="#fbbf24" />
    <circle frame="12,12" color="#fff7ed" />
    <vstack frame="max" alignment="leading" padding="12">
      <text font="caption" weight="bold" color="#fce7f3">GOLDEN BLOOM</text>
      <spacer />
      <text font="caption2" color="#f9a8d4">φ · 137.507764°</text>
    </vstack>
  </zstack>
);
