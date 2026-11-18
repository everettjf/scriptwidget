//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
// Usage for api $http
// Calls $http.get and $http.post in several forms and prints each answer to the Console.
// A Package 2.0 widget needs the "network" permission in widget.json, and the host
// of the URL in networkDomains.
// Runs on iPhone, iPad, Mac, Android, Windows and Linux.
//

// $http.get
// $http.get works like fetch and $fetch: it gives back the body of the response as text.
const get_result = await $http.get("https://jsonplaceholder.typicode.com/todos/1");
console.log(get_result);

// query json example with header
// https://docs.github.com/en/rest/reference/projects
const get_with_header_result = await $http.get("https://api.github.com/users/everettjf/orgs", {
  headers: {
    Accept: "application/vnd.github.inertia-preview+json",
  },
});
console.log(get_with_header_result);

// $http.post
// The body here is an object.
const post_result = await $http.post("https://jsonplaceholder.typicode.com/posts", {
  body: {
    userId: 1,
    id: 1,
    title: "Hello ScriptWidget",
  },
});
console.log(post_result);

// A POST request with a header.
const post_with_header_result = await $http.post("https://jsonplaceholder.typicode.com/posts", {
  headers: {
    Accept: "application/vnd.github.inertia-preview+json",
  },
  body: {
    userId: 1,
    id: 1,
    title: "Hello ScriptWidget",
  },
});
console.log(post_with_header_result);

// The body can also be text, here form fields.
const post_string_with_header_result = await $http.post(
  "https://jsonplaceholder.typicode.com/posts",
  {
    headers: {
      Accept: "application/vnd.github.inertia-preview+json",
    },
    body: "password=123&name=321",
  },
);
console.log(post_string_with_header_result);

// $http.put (same to post)
// $http.patch (same to post)
// $http.delete (same to post)

// responseType: "base64"
// By default the response is decoded as UTF-8 text. For binary resources
// (such as images) pass responseType: "base64" to get the raw bytes back as
// a Base64 string. This is useful when the resource needs custom headers
// (e.g. a Referer / Cookie) that the <image url="..."> tag cannot send.
//
// const base64 = await $http.get("https://example.com/camera.jpg", {
//   headers: { Referer: "https://example.com/webcam-page/" },
//   responseType: "base64",
// });
// $render(
//   <image url={`data:image/jpeg;base64,${base64}`} mode="fit" frame="340,340" />
// );

// Draw something, so the widget is not empty. The results are in the Console.
$render(
  <vstack>
    <text>$http example</text>
  </vstack>,
);
