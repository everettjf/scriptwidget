# HTTP response metadata

<!-- platforms:start -->
> **Runs on:** iPhone and iPad, Mac, Android, Windows, Linux. Details and limits: [Platform support](platform-support.md).
<!-- platforms:end -->

Native API 1.3 adds `$http.getResponse(url, options?)`. It returns a Promise of `{status, body, headers}`. `body` is a string, using the same decoding options as `$http.get`; existing HTTP methods keep their string return values. HTTP error statuses resolve with their response; transport and policy failures reject.

Only these response headers are exposed, lowercased: `content-type`, `cache-control`, `expires`, `last-modified`, `date`, and `retry-after`. Each is limited to 2,048 UTF-8 bytes. Cookies, credentials and arbitrary response headers are excluded. The existing response-byte budget, public-host restrictions, declared network permission/domains, redirect checks and execution-session checks still apply. This method grants no additional access.

```javascript
const response = await $http.getResponse("https://example.com/forecast", {
  headers: {"If-Modified-Since": savedLastModified}
});
if (response.status === 304) {
  // Retain the saved body and update its next permitted request time.
} else if (response.status === 200) {
  const forecast = JSON.parse(response.body);
  // Validate the payload before saving or rendering it.
}
```

Web Studio uses the matching editable fetch Mock fixture. Fixtures may specify `status` (integer 100–599) and string-valued `headers`; omitted status defaults to 200. The same safe response-header filter applies. Default MET Norway responses are synthetic healthy forecasts for the default Mock position, not measurements or live weather. Package export does not grant or embed the editor's Mock environment.

The built-in weather examples use this API for expiry, conditional requests and retry backoff. Their README documents location disclosure, cache limits and MET Norway attribution. The bundled `Weather Now (Open-Meteo)` example has been replaced by `Weather Now (MET Norway)`; existing installed user packages are not rewritten.
