// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Usage for component image
// 

/*

    <image />
    <image systemName="mosaic.fill" />
    <image id="image0" />
    
    <image id="image" mode="fit" ratio="0.6" />
    <image id="image" mode="fill" frame="260,60" />

    <image id="image" mode="fill" clip frame="200,100"/>
    
    <image id="image" mode="fill" clip="rect" frame="200,100"/>
    <image id="image" mode="fill" clip="ellipse" frame="200,100"/>
    <image id="image" mode="fill" clip="circle" frame="200,100"/>
    <image id="image" mode="fill" clip="capsule" frame="200,100"/>

    <image id="image" mode="fill" corner="30" frame="200,100"/>
*/

$render(
  <zstack frame="max" background="#0f172a">
    <image id="image" mode="fill" frame="max"/>
    <vstack frame="max,bottomLeading" alignment="leading" padding="14"><spacer/><badge text="LOCAL IMAGE" color="white"/><text font="title2" weight="bold" color="white">Photo spotlight</text></vstack>
  </zstack>
);
