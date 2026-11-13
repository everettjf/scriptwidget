// Android host for the shared ScriptWidget execution kernel. Evaluated first
// in a fresh QuickJS context, before the kernel and any package code.
//
// It captures the two native entry points and removes them from the global
// object, supplies the Intl subset that QuickJS lacks, and defines the boot
// function Kotlin calls once per execution. Package code never sees a native
// entry point or the driver.
(function (global) {
  "use strict";
  const native = global.__swNative;
  const evaluateGlobal = global.__swEvaluate;
  delete global.__swNative;
  delete global.__swEvaluate;

  const JSONParse = JSON.parse;
  const JSONStringify = JSON.stringify;
  const RealDate = Date;
  const dateNow = Date.now;
  const getTime = Function.prototype.call.bind(Date.prototype.getTime);
  const ObjectKeys = Object.keys;
  const hasOwn = Function.prototype.call.bind(Object.prototype.hasOwnProperty);

  /// Synchronous native call. Payloads and results are JSON.
  function call(operation, payload) {
    const result = native(operation, payload === undefined ? null : JSONStringify(payload));
    return result === null ? null : JSONParse(result);
  }
  /// Synchronous native call that passes and returns raw text.
  function callText(operation, text) { return native(operation, text === undefined ? null : text); }

  // MARK: - Intl subset backed by ICU on the device

  const dateFields = ["weekday", "era", "year", "month", "day"];
  const timeFields = ["dayPeriod", "hour", "minute", "second", "fractionalSecondDigits"];
  const dateOptionNames = [...dateFields, ...timeFields, "timeZoneName", "timeZone", "hour12", "hourCycle", "dateStyle", "timeStyle", "calendar", "numberingSystem"];
  const numberOptionNames = ["style", "currency", "currencyDisplay", "unit", "unitDisplay", "notation", "compactDisplay", "useGrouping", "signDisplay",
    "minimumIntegerDigits", "minimumFractionDigits", "maximumFractionDigits", "minimumSignificantDigits", "maximumSignificantDigits"];

  function pickLocale(locales) {
    if (typeof locales === "string" && locales !== "") return locales;
    if (Array.isArray(locales) && typeof locales[0] === "string" && locales[0] !== "") return locales[0];
    return callText("intl.locale");
  }

  function pickOptions(options, names) {
    const result = {};
    if (options === undefined || options === null) return result;
    if (typeof options !== "object") throw new TypeError("Intl options must be an object");
    for (const name of names) {
      const value = options[name];
      if (value !== undefined) result[name] = typeof value === "boolean" || typeof value === "number" ? value : String(value);
    }
    return result;
  }

  /// ECMA-402 ToDateTimeOptions: add default fields when none were requested.
  function withDateDefaults(options, required, defaults) {
    const result = { ...options };
    if (result.dateStyle !== undefined || result.timeStyle !== undefined) return result;
    const needDate = required !== "time" && dateFields.some((field) => result[field] !== undefined);
    const needTime = required !== "date" && timeFields.some((field) => result[field] !== undefined);
    if (needDate || needTime) return result;
    if (defaults === "date" || defaults === "all") { result.year = "numeric"; result.month = "numeric"; result.day = "numeric"; }
    if (defaults === "time" || defaults === "all") { result.hour = "numeric"; result.minute = "numeric"; result.second = "numeric"; }
    return result;
  }

  function timeValue(date) {
    if (date === undefined) return dateNow();
    const value = date instanceof RealDate ? getTime(date) : Number(date);
    if (!Number.isFinite(value)) throw new RangeError("Invalid time value");
    return value;
  }

  // Function constructors: Intl.DateTimeFormat() and Intl.NumberFormat() are
  // callable without `new`, which a class is not.
  function DateTimeFormat(locales, options) {
    if (!(this instanceof DateTimeFormat)) return new DateTimeFormat(locales, options);
    const locale = pickLocale(locales);
    const resolved = withDateDefaults(pickOptions(options, dateOptionNames), "any", "date");
    if (resolved.timeZone !== undefined && callText("intl.validZone", resolved.timeZone) !== "1") {
      throw new RangeError("Invalid time zone specified: " + resolved.timeZone);
    }
    Object.defineProperty(this, "__sw", { value: { locale, options: resolved } });
    this.format = (date) => callText("intl.date", JSONStringify({ locale, options: resolved, time: timeValue(date) }));
  }
  DateTimeFormat.prototype.formatToParts = function (date) {
    return call("intl.dateParts", { locale: this.__sw.locale, options: this.__sw.options, time: timeValue(date) });
  };
  DateTimeFormat.prototype.resolvedOptions = function () {
    const state = this.__sw;
    return { locale: state.locale, calendar: "gregory", numberingSystem: "latn", ...state.options, timeZone: state.options.timeZone ?? callText("intl.timeZone") };
  };
  DateTimeFormat.supportedLocalesOf = (locales) => (typeof locales === "string" ? [locales] : Array.isArray(locales) ? locales.slice() : []);

  function NumberFormat(locales, options) {
    if (!(this instanceof NumberFormat)) return new NumberFormat(locales, options);
    const locale = pickLocale(locales);
    const resolved = pickOptions(options, numberOptionNames);
    Object.defineProperty(this, "__sw", { value: { locale, options: resolved } });
    this.format = (value) => callText("intl.number", JSONStringify({ locale, options: resolved, value: String(typeof value === "bigint" ? value : Number(value)) }));
  }
  NumberFormat.prototype.formatToParts = function (value) { return [{ type: "literal", value: this.format(value) }]; };
  NumberFormat.prototype.resolvedOptions = function () { return { locale: this.__sw.locale, numberingSystem: "latn", style: "decimal", ...this.__sw.options }; };
  NumberFormat.supportedLocalesOf = DateTimeFormat.supportedLocalesOf;

  class PluralRules {
    constructor(locales, options) {
      Object.defineProperty(this, "__sw", { value: { locale: pickLocale(locales), type: options?.type === "ordinal" ? "ordinal" : "cardinal" } });
    }
    select(value) { return callText("intl.plural", JSONStringify({ locale: this.__sw.locale, type: this.__sw.type, value: Number(value) })); }
    resolvedOptions() { return { locale: this.__sw.locale, type: this.__sw.type }; }
    static supportedLocalesOf(locales) { return DateTimeFormat.supportedLocalesOf(locales); }
  }

  class RelativeTimeFormat {
    constructor(locales, options) {
      Object.defineProperty(this, "__sw", { value: { locale: pickLocale(locales), options: pickOptions(options, ["numeric", "style"]) } });
    }
    format(value, unit) { return callText("intl.relative", JSONStringify({ locale: this.__sw.locale, options: this.__sw.options, value: Number(value), unit: String(unit) })); }
    resolvedOptions() { return { locale: this.__sw.locale, numberingSystem: "latn", numeric: "always", style: "long", ...this.__sw.options }; }
    static supportedLocalesOf(locales) { return DateTimeFormat.supportedLocalesOf(locales); }
  }

  class Collator {
    constructor(locales) {
      const locale = pickLocale(locales);
      Object.defineProperty(this, "__sw", { value: { locale } });
      this.compare = (left, right) => Number(callText("intl.compare", JSONStringify({ locale, left: String(left), right: String(right) })));
    }
    resolvedOptions() { return { locale: this.__sw.locale, usage: "sort", sensitivity: "variant" }; }
    static supportedLocalesOf(locales) { return DateTimeFormat.supportedLocalesOf(locales); }
  }

  class ListFormat {
    constructor(locales, options) {
      Object.defineProperty(this, "__sw", { value: { locale: pickLocale(locales), options: pickOptions(options, ["type", "style"]) } });
    }
    format(list) { return callText("intl.list", JSONStringify({ locale: this.__sw.locale, options: this.__sw.options, items: Array.from(list, String) })); }
    static supportedLocalesOf(locales) { return DateTimeFormat.supportedLocalesOf(locales); }
  }

  const define = (target, name, value) => Object.defineProperty(target, name, { value, writable: true, configurable: true, enumerable: false });
  const Intl = {};
  define(Intl, "DateTimeFormat", DateTimeFormat);
  define(Intl, "NumberFormat", NumberFormat);
  define(Intl, "PluralRules", PluralRules);
  define(Intl, "RelativeTimeFormat", RelativeTimeFormat);
  define(Intl, "Collator", Collator);
  define(Intl, "ListFormat", ListFormat);
  define(Intl, "getCanonicalLocales", (locales) => DateTimeFormat.supportedLocalesOf(locales));
  define(global, "Intl", Intl);

  function dateToLocale(required, defaults) {
    return function (locales, options) {
      const time = getTime(this);
      if (!Number.isFinite(time)) return "Invalid Date";
      const resolved = withDateDefaults(pickOptions(options, dateOptionNames), required, defaults);
      return callText("intl.date", JSONStringify({ locale: pickLocale(locales), options: resolved, time }));
    };
  }
  define(RealDate.prototype, "toLocaleString", dateToLocale("any", "all"));
  define(RealDate.prototype, "toLocaleDateString", dateToLocale("date", "date"));
  define(RealDate.prototype, "toLocaleTimeString", dateToLocale("time", "time"));
  define(Number.prototype, "toLocaleString", function (locales, options) {
    return callText("intl.number", JSONStringify({ locale: pickLocale(locales), options: pickOptions(options, numberOptionNames), value: String(Number(this)) }));
  });
  define(String.prototype, "localeCompare", function (other, locales) {
    return Number(callText("intl.compare", JSONStringify({ locale: pickLocale(locales), left: String(this), right: String(other) })));
  });

  // MARK: - Globals JavaScriptCore does not provide

  // A script that relies on these would work on Android and fail on iPhone,
  // so they are removed, exactly as the browser host hides them.
  for (const name of ["queueMicrotask", "performance", "navigator", "gc", "print", "std", "os", "bjson"]) {
    if (hasOwn(global, name)) { try { delete global[name]; } catch { /* non-configurable */ } }
  }

  // MARK: - Native API installers registered by the other host files

  const installers = [];
  global.__swRegisterAPIs = (installer) => { installers.push(installer); };

  // MARK: - Boot

  /// Kotlin calls __swBoot(token, jobJSON) once. The driver that Kotlin uses
  /// afterwards is stored under the unguessable token.
  global.__swBoot = function (token, jobText) {
    const kernel = global.__swKernel;
    delete global.__swBoot;
    delete global.__swKernel;
    delete global.__swRegisterAPIs;
    const job = JSONParse(jobText);

    const deferred = [];
    let timeoutCallback = null;
    let finished = false;
    const pending = new Map();
    let nextAsyncID = 1;

    /// Starts a native operation that completes later on the JavaScript thread.
    function callAsync(operation, payload, resolve, reject) {
      const id = nextAsyncID;
      nextAsyncID += 1;
      pending.set(id, { resolve, reject });
      try {
        native("async.start", JSONStringify({ id, operation, payload: payload === undefined ? null : payload }));
      } catch (error) {
        pending.delete(id);
        reject(String(error?.message ?? error));
      }
    }

    const host = {
      evaluateScript(code) { evaluateGlobal(code, "script.js"); },
      compiledImport(path) { return callText("package.import", String(path)); },
      readFile(path) { return callText("package.read", String(path)); },
      fileExists(path) { return callText("package.exists", String(path)) === "1"; },
      supportScript(name) { return callText("support.script", String(name)); },
      parseXML(source) { return callText("xml.parse", String(source)); },
      log(level, message) { callText("log." + level, String(message)); },
      defer(callback) { deferred.push(callback); },
      timeout(_milliseconds, callback) { timeoutCallback = callback; },
      finish(resultJSON) {
        if (finished) return;
        finished = true;
        callText("finish", resultJSON);
      },
      installNativeAPIs(apis, helpers) {
        const bridge = { call, callText, callAsync, job };
        for (const installer of installers) installer(apis, helpers, bridge);
      },
    };

    Object.defineProperty(global, token, {
      enumerable: false, configurable: false, writable: false,
      value: function driver(command, first, second, third) {
        if (command === "pump") {
          const callback = deferred.shift();
          if (!callback) return "0";
          callback();
          return "1";
        }
        if (command === "resolve") {
          const entry = pending.get(Number(first));
          if (!entry) return "0";
          pending.delete(Number(first));
          const value = third === null || third === undefined ? null : JSONParse(third);
          if (second === "1") entry.resolve(value); else entry.reject(value);
          return "1";
        }
        if (command === "timeout") {
          const callback = timeoutCallback;
          timeoutCallback = null;
          if (callback) callback();
          return "1";
        }
        if (command === "idle") return pending.size === 0 && deferred.length === 0 ? "1" : "0";
        return "0";
      },
    });

    kernel(global, host, job.config).run(job.code, job.timeoutMilliseconds);
  };
})(globalThis);
