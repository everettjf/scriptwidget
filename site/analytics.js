(function () {
  "use strict";

  var allowedParameters = ["utm_source", "utm_medium", "utm_campaign", "utm_content"];
  var query = new URLSearchParams(window.location.search);
  var attribution = {};

  allowedParameters.forEach(function (name) {
    var value = query.get(name);
    if (value) {
      attribution[name] = value.slice(0, 100);
    }
  });

  if (Object.keys(attribution).length > 0) {
    try {
      window.sessionStorage.setItem("scriptwidget_attribution", JSON.stringify(attribution));
    } catch (_) {
      // Attribution remains available for this page view when storage is unavailable.
    }
  } else {
    try {
      attribution = JSON.parse(window.sessionStorage.getItem("scriptwidget_attribution")) || {};
    } catch (_) {
      attribution = {};
    }
  }

  function track(name, properties) {
    var eventProperties = Object.assign({}, attribution, properties || {});
    window.dataLayer = window.dataLayer || [];
    window.dataLayer.push({ event: name, properties: eventProperties });

    if (typeof window.plausible === "function") {
      window.plausible(name, { props: eventProperties });
    }

    window.dispatchEvent(new CustomEvent("xnu:analytics", {
      detail: { name: name, properties: eventProperties }
    }));
  }

  window.xnuTrack = track;
  track("landing_view", { page: "scriptwidget" });

  document.querySelectorAll("[data-track-event]").forEach(function (link) {
    link.addEventListener("click", function () {
      track(link.dataset.trackEvent, {
        label: link.dataset.trackLabel || "",
        destination: link.hostname
      });
    });
  });
}());
