
//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// basic clock animation
//


$render(
  <vstack frame="max,center">
      <zstack>
          <vstack animation="clockSecond">
              <rect frame="5,50" color="yellow"></rect>
              <rect frame="5,50" color="clear"></rect>
          </vstack>
          <vstack animation="clockMinute">
              <rect frame="5,40" color="blue"></rect>
              <rect frame="5,40" color="clear"></rect>
          </vstack>
          <vstack animation="clockHour">
              <rect frame="5,30" color="red"></rect>
              <rect frame="5,30" color="clear"></rect>
          </vstack>
      </zstack>
  </vstack>
);

