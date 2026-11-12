//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// image systemName with font size
//
// Description: image with systemName is special.
//      Attribute frame does not work with image with systemName.
//      But it's sizes can be set by attribute font with a number size.
//

$render(
  <vstack>
    <image systemName="battery.100.bolt" font="10" />
    <image systemName="battery.100.bolt" font="20" />
    <image systemName="battery.100.bolt" font="30" />
    <image systemName="battery.100.bolt" font="40" />
  </vstack>
);
