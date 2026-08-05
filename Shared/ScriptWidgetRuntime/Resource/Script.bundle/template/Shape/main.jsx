// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Shape Template
// 
// Description: Shape Example
// 


$render(
  <hstack frame="max" spacing="18" padding="14" background="#1e1b4b">
    <zstack frame="100,100" animation="clockCustom,20"><roundedrect frame="86,86" color="#7c3aed" radius="22"/><circle frame="58,58" color="#c4b5fd"/><roundedrect frame="28,28" color="#f8fafc" radius="8"/></zstack>
    <vstack alignment="leading" spacing="4"><text font="caption" color="#c4b5fd">SHAPES</text><text font="title2" weight="bold" color="white">Build with primitives</text><text font="caption" color="#ddd6fe">Compose, color, rotate.</text></vstack>
  </hstack>
);
