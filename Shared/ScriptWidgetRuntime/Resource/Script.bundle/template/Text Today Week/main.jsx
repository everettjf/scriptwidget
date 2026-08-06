// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// 

var d = new Date();

const weekday = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
let day = weekday[d.getDay()];


$render(
    <hstack background="#e11d48" frame="max" spacing="16" padding="14">
      <vstack alignment="leading" spacing="3"><text font="caption" color="#fca5a5">TODAY</text><text font="largeTitle" weight="bold" color="white">{day}</text><date date="now" style="date" font="caption" color="#fecaca"/></vstack><spacer/><icon systemName="calendar.circle.fill" size="44" color="#f87171"/>
    </hstack>
);
