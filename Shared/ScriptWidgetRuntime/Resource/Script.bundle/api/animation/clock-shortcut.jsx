
//
// ScriptWidget
// https://xnu.app/scriptwidget
//
// another basic clock animation
//


$render(
  <vstack frame="max,center">
      <zstack>
          <vstack animation="clockHour">
              <circle frame="15,15" color="red"></circle>
              <spacer/>
          </vstack>
          <vstack animation="clockMinute">
              <circle frame="10,10" color="blue"></circle>
              <spacer/>
          </vstack>
          <vstack animation="clockSecond">
              <circle frame="5,5" color="yellow"></circle>
              <spacer/>
          </vstack>
      </zstack>
  </vstack>
);

