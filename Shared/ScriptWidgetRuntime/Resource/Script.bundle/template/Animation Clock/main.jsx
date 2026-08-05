
//
// ScriptWidget
// https://xnu.app/scriptwidget
//
//


$render(
  <hstack frame="max" spacing="18" padding="14" background="#111827">
    <zstack frame="112,112">
      <circle frame="108,108" color="#1f2937"/>
      <vstack animation="clockSecond"><rect frame="3,46" color="#fb7185" corner="2"/><rect frame="3,46" color="clear"/></vstack>
      <vstack animation="clockMinute"><rect frame="5,38" color="#60a5fa" corner="3"/><rect frame="5,38" color="clear"/></vstack>
      <vstack animation="clockHour"><rect frame="6,28" color="#f8fafc" corner="3"/><rect frame="6,28" color="clear"/></vstack>
      <circle frame="10,10" color="#f8fafc"/>
    </zstack>
    <vstack alignment="leading" spacing="4"><text font="caption" color="#94a3b8">ANALOG CLOCK</text><date date="now" style="time" font="title2" weight="bold" color="white"/><date date="now" style="date" font="caption" color="#60a5fa"/></vstack>
  </hstack>
);
