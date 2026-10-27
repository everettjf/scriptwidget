// Runtime 1.6 system capabilities; metadata never grants native access.
export const systemAPICatalog = [
  {
    "id": "$notifications.status",
    "group": "notifications",
    "value": {
      "authorization": "authorized"
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeNotifications.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$notifications.pending",
    "group": "notifications",
    "value": [],
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeNotifications.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$notifications.schedule",
    "group": "notifications",
    "value": {
      "key": "daily",
      "status": "scheduled"
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeNotifications.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$notifications.cancel",
    "group": "notifications",
    "value": {
      "key": "daily",
      "status": "cancellationRequested"
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "key"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeNotifications.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$health.dailyStatistics",
    "group": "health",
    "value": {
      "metric": "steps",
      "unit": "count",
      "aggregation": "sum",
      "timeZone": "UTC",
      "items": [
        {
          "date": "2026-01-01",
          "value": 6840,
          "hasSamples": true
        }
      ]
    },
    "platforms": [
      "ios"
    ],
    "authorization": "healthRead",
    "notes": "Runtime 1.6. Read-only daily HealthKit statistics on installed iPhone/iPad widgets. Declare health and minimumRuntimeVersion 1.6, review Health access in native Settings. No separate System Access toggle. Missing readings are null/hasSamples false and cannot establish read denial. No raw samples, persistence or queries in future/Live Activity presentations. Preview fixtures never access real Health data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeHealth.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$calendar.create",
    "group": "calendar",
    "value": {
      "id": "sample.event",
      "calendarID": "sample.calendar",
      "status": "applied",
      "replayed": false
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data. Calendar writes need calendar and calendarWrite; updates are limited to events this installation created.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeCalendar.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$calendar.update",
    "group": "calendar",
    "value": {
      "id": "sample.event",
      "calendarID": "sample.calendar",
      "status": "applied",
      "replayed": false
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data. Calendar writes need calendar and calendarWrite; updates are limited to events this installation created.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeCalendar.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$weather.forecast",
    "group": "weather",
    "value": {
      "provider": "MET Norway",
      "attribution": {
        "text": "Weather data from MET Norway",
        "url": "https://www.met.no/en/free-meteorological-data/Download-services"
      },
      "latitude": 37.33,
      "longitude": -122.01,
      "fetchedAt": "2026-01-01T12:00:00Z",
      "isStale": false,
      "hours": [
        {
          "time": "2026-01-01T12:00:00Z",
          "temperatureC": 21,
          "windMetersPerSecond": 2,
          "precipitationMM": 0,
          "condition": "partlycloudy_day"
        }
      ]
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeWeather.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$alarms.status",
    "group": "alarms",
    "value": {
      "authorization": "authorized"
    },
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeAlarms.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$alarms.pending",
    "group": "alarms",
    "value": [],
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeAlarms.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$alarms.schedule",
    "group": "alarms",
    "value": {
      "key": "focus",
      "status": "scheduled",
      "replayed": false
    },
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeAlarms.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$alarms.cancel",
    "group": "alarms",
    "value": {
      "key": "focus",
      "status": "requested"
    },
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "key"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeAlarms.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$alarms.stop",
    "group": "alarms",
    "value": {
      "key": "focus",
      "status": "requested"
    },
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "key"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeAlarms.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$alarms.pause",
    "group": "alarms",
    "value": {
      "key": "focus",
      "status": "requested"
    },
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "key"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeAlarms.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$alarms.resume",
    "group": "alarms",
    "value": {
      "key": "focus",
      "status": "requested"
    },
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "key"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeAlarms.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$documents.list",
    "group": "documents",
    "value": [
      {
        "id": "550e8400-e29b-41d4-a716-446655440000",
        "name": "Sample.json",
        "type": "json",
        "bytes": 17
      },
      {
        "id": "550e8400-e29b-41d4-a716-446655440001",
        "name": "Sample.csv",
        "type": "csv",
        "bytes": 24
      }
    ],
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeDocuments.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$documents.readJSON",
    "group": "documents",
    "value": {
      "goal": 12,
      "done": 7
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "id"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeDocuments.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$documents.readCSV",
    "group": "documents",
    "value": {
      "headers": [
        "day",
        "value"
      ],
      "rows": [
        [
          "Monday",
          "7"
        ],
        [
          "Tuesday",
          "9"
        ]
      ],
      "truncated": false
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "id"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeDocuments.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$contacts.selected",
    "group": "contacts",
    "value": [
      {
        "id": "sample.contact",
        "name": "Alex Example",
        "organization": "Sample",
        "phones": [
          "+1 202 555 0100"
        ],
        "emails": [
          "alex@example.com"
        ]
      }
    ],
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeContacts.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$maps.search",
    "group": "maps",
    "value": [
      {
        "name": "Example Park",
        "address": "Sample address",
        "latitude": 37.33,
        "longitude": -122.01
      }
    ],
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeMaps.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$maps.geocode",
    "group": "maps",
    "value": [
      {
        "name": "Example Park",
        "address": "Sample address",
        "latitude": 37.33,
        "longitude": -122.01
      }
    ],
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "address"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeMaps.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$maps.reverseGeocode",
    "group": "maps",
    "value": [
      {
        "name": "Example Park",
        "address": "Sample address",
        "latitude": 37.33,
        "longitude": -122.01
      }
    ],
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeMaps.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$maps.snapshot",
    "group": "maps",
    "value": {
      "image": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==",
      "width": 256,
      "height": 256,
      "provider": "Apple Maps"
    },
    "platforms": [
      "ios",
      "macos"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeMaps.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$home.items",
    "group": "home",
    "value": [
      {
        "id": "sample.light",
        "name": "Living Room Lamp",
        "kind": "power",
        "value": true,
        "isCached": true,
        "metric": "power",
        "unit": "boolean"
      },
      {
        "id": "scene-sample",
        "name": "Evening",
        "kind": "scene",
        "value": null,
        "isCached": true,
        "metric": "scene",
        "unit": "none"
      }
    ],
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeHome.swift",
    "operation": "read",
    "mock": "editable"
  },
  {
    "id": "$home.setPower",
    "group": "home",
    "value": {
      "id": "sample.light",
      "value": true,
      "status": "acknowledged"
    },
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeHome.swift",
    "operation": "write",
    "mock": "editable"
  },
  {
    "id": "$home.runScene",
    "group": "home",
    "value": {
      "id": "scene-sample",
      "status": "acknowledged",
      "replayed": false
    },
    "platforms": [
      "ios"
    ],
    "authorization": "systemAccess",
    "notes": "Runtime 1.6. Installed widgets require manifest permission, explicit native System Access, system authorization where applicable, an active installation and bounded queries. Writes require a user action; future timelines and Live Activities cannot call this API. Web and CLI fixtures never access real device data.",
    "arguments": [
      "options"
    ],
    "asynchronous": true,
    "minimumRuntimeVersion": "1.6",
    "nativeSource": "Shared/ScriptWidgetRuntime/Widget/API/ScriptWidgetRuntimeHome.swift",
    "operation": "write",
    "mock": "editable"
  }
];
