// 
// ScriptWidget 
// https://xnu.app/scriptwidget
// 
// Usage for api $http
// 

// $http.get
// $http.get is identity to $fetch or fetch api
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
const post_result = await $http.post("https://jsonplaceholder.typicode.com/posts", {
  body: {
    userId: 1,
    id: 1,
    title: "Hello ScriptWidget",
  }
});
console.log(post_result);

const post_with_header_result = await $http.post("https://jsonplaceholder.typicode.com/posts", {  
  headers: {
    Accept: "application/vnd.github.inertia-preview+json",
  },
  body: {
    userId: 1,
    id: 1,
    title: "Hello ScriptWidget",
  }
});
console.log(post_with_header_result);

const post_string_with_header_result = await $http.post("https://jsonplaceholder.typicode.com/posts", {  
  headers: {
    Accept: "application/vnd.github.inertia-preview+json",
  },
  body: "password=123&name=321"
});
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

$render(
  <vstack>
    <text>$http example</text>
  </vstack>
);
