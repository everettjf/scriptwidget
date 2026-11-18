//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api file
// Reads data.json, a file inside this widget package. Paths start at the package folder.
// The results go to the Console.
// Nothing is drawn here, so the widget itself only shows "#UI Not Found#".
// Runs on iPhone, iPad, Mac, Android, Windows and Linux.
//

// read as string
console.log($file.read("data.json"));

// read as json
let json = $file.readJSON("data.json");
console.log(json);
console.log(json.name);
