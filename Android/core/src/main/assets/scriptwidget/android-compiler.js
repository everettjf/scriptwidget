// Evaluated in the long-lived compiler context after the Babel bundle and
// the prepare bundle. Package code never runs here.
(function (global) {
  "use strict";
  const Babel = global.Babel;
  const prepare = global.__swPrepareBundle;
  delete global.Babel;
  delete global.__swPrepareBundle;
  delete global.__swBoot;
  delete global.__swRegisterAPIs;
  const compiler = prepare.createCompiler((source) => Babel.transform(source, { presets: ["scriptwidget"] }).code);

  global.__swPrepare = function (jobText) {
    const job = JSON.parse(jobText);
    const files = Object.assign(Object.create(null), job.files);
    // Binary resources only need to exist for manifest validation.
    for (const path of job.binaries ?? []) files[path] = new Uint8Array(0);
    let prepared;
    try {
      const options = { files, prelude: job.prelude ?? "", manifest: job.manifest ?? null, actionID: job.actionID ?? null };
      if (typeof job.entry === "string") options.entry = job.entry;
      prepared = prepare.preparePackage(compiler, options);
    } catch (error) {
      prepared = { ok: false, error: { kind: "internalError", message: String(error) } };
    }
    if (prepared.ok) delete prepared.files;
    return JSON.stringify(prepared);
  };

  global.__swTimeline = function (scheduleText, nowMilliseconds, systemTimeZone) {
    const plan = prepare.buildTimelinePlan(JSON.parse(scheduleText), new Date(Number(nowMilliseconds)), new Date(Number(nowMilliseconds) + 3600000), systemTimeZone);
    return JSON.stringify(plan);
  };

  global.__swValidateManifest = function (text, pathsText) {
    const decoded = prepare.decodeManifest(text);
    if (decoded.error) return JSON.stringify({ ok: false, error: decoded.error, issues: [] });
    const report = prepare.validateManifest(decoded.manifest, JSON.parse(pathsText), { checkEntryExists: true });
    return JSON.stringify({ ok: !report.issues.some((item) => item.severity === "error"), manifest: decoded.manifest, issues: report.issues });
  };
})(globalThis);
