// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Weather Template
// 
// Description: Display weather today
// 

const result = await fetch("https://api.open-meteo.com/v1/forecast?latitude=39.9042&longitude=116.4074&current=temperature_2m,apparent_temperature,weather_code&timezone=auto");
const data = JSON.parse(result).current || {};
const conditions = {0:"Clear",1:"Mostly clear",2:"Partly cloudy",3:"Overcast",45:"Fog",61:"Rain",71:"Snow",95:"Thunderstorm"};
const condition = conditions[data.weather_code] || "Mixed skies";

$render(
  <vstack frame="max" alignment="leading" spacing="6" padding="16" background="#2563eb">
    <hstack frame="max"><text font="caption" weight="bold" color="#bfdbfe">BEIJING</text><spacer/><icon systemName="cloud.sun.fill" size="24" color="#fde68a"/></hstack>
    <spacer/>
    <text font="largeTitle" weight="bold" color="white">{Math.round(data.temperature_2m)}°</text>
    <text font="headline" color="white">{condition}</text>
    <text font="caption" color="#dbeafe">Feels like {Math.round(data.apparent_temperature)}°</text>
  </vstack>
);
