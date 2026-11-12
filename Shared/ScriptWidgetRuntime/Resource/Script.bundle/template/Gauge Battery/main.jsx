// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Battery Gauge
// 

var percent = $device.battery().level * 100;
percent = percent.toFixed(0);

let gaugeSections = [
  {color: "yellow", value: 0.1},
  {color: "blue", value: 0.2},
  {color: "orange", value: 0.3},
  {color: "green", value: 0.4},
];


$render(
  <vstack frame="max">
    <gauge 
      angle="260" 
      value={percent/100}
      thickness="10" 
      label={percent + "%"} labelFont="caption"
      title="BATTERY" titleFont="caption"
      sections={$json(gaugeSections)}
      >
    </gauge>
  </vstack>
);
