// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
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
  <vstack>
    <image url="https://zos.alipayobjects.com/rmsportal/ODTLcjxAfvqbxHnVXCYX.png" frame="20,20"/>
    <image id="image" frame="260,60"/>
  </vstack>
);
