// 
// ScriptWidget 
// https://atomsprout.com/scriptwidget
// 
// Usage for component attribute frame
// 

/*

 frame="max"
 frame="max,topLeading"
 frame="10,20"
 frame="10,20,topLeading"
 
 frame="max,20"
 frame="10,max"
 frame="max,20,topLeading"
 frame="10,max,topLeading"


 the "topLeading" represent alignment, could be one of the values below:
    "center"
    "leading"
    "trailing"
    "top"
    "bottom"
    "topLeading"
    "topTrailing"
    "bottomLeading"
    "bottomTrailing"
*/
$render(
  <vstack frame="max">
    <rect frame="50,30" color="green"></rect>
    <rect frame="50,30" color="blue" corner="5"></rect>
  </vstack>
);
