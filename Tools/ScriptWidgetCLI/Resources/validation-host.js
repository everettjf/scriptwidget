(function (catalog, fixtures, dark) {
  'use strict';
  const permit = __validationPermit;
  const note = __validationDiagnostic;
  const reserve = __validationReserve;
  delete globalThis.__validationReserve;
  let networkRequests = 0;
  const reported = new Set();
  delete globalThis.__validationDiagnostic;
  delete globalThis.__validationPermit;
  const copy = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  const asyncValue = call => ({then(resolve, reject) { try { return resolve(call()); } catch (e) { if (reject) return reject(String(e)); throw e; }}});
  const includes = Function.prototype.call.bind(Array.prototype.includes);
  const groups = {};
  const caps = {health:'health',location:'location',calendar:'calendar',photos:'photos',reminders:'reminders',services:'services',music:'music',notifications:'notifications',alarms:'alarms',maps:'maps',weather:'weather',documents:'documents',contacts:'contacts',home:'home'};
  for (const item of catalog) {
    const [group, method] = item.id.split('.');
    const object = groups[group] ?? (groups[group] = {});
    object[method] = function () {
      const args = Array.from(arguments);
      const call = () => {
        if (item.minimumRuntimeVersion === '1.6' && !permit('runtime1.6','')) throw Error('[system_runtime] Declare minimumRuntimeVersion 1.6 or later');
        if (item.minimumRuntimeVersion === '1.6' && item.operation === 'write') throw Error('[read_only] Native CLI renders cannot run system actions');
        const capability = item.group === 'calendar' && includes(['create','update'],method) ? 'calendarWrite' : item.group === 'reminders' && includes(['create','update','setCompleted'],method) ? 'remindersWrite' : caps[item.group];
        if (capability && !includes(['isAvailable','authorizationStatus','isAuthorizedForWidgetUpdates'],method) && !permit(capability,'')) throw Error('[permission_denied] Declare '+capability+' in widget.json');
        if (args.length && !reported.has(item.id)) {reported.add(item.id); note('mock.arguments_not_validated','Offline reply for '+item.id+' does not certify real system query arguments.');}
        if (capability && item.operation === 'read' && !reserve()) throw Error('[resource_limit] System-data query budget exceeded');
        const status=fixtures.api && fixtures.api[group+'.authorizationStatus'];
        if (!includes(['isAvailable','authorizationStatus','requestAuthorization'],method) && status && includes(['denied','restricted','notDetermined','unavailable'],status.value)) throw Error('[permission_denied] Simulated system authorization is '+status.value);
        const rule = fixtures.api && fixtures.api[item.id];
        if (rule && 'error' in rule) throw Error(rule.error);
        if (item.id === '$device.isdarkmode' && !rule) return dark;
        if (rule) return copy(rule.value);
        if (item.operation === 'write') throw Error('[fixture.unsupported] Supply an explicit mock for '+item.id);
        return copy(item.value);
      };
      return item.asynchronous ? asyncValue(call) : call();
    };
  }
  for (const group of Object.keys(groups)) globalThis[group] = Object.freeze(groups[group] || {});
  function http(method, url, metadata) {
    return asyncValue(() => {
      if (++networkRequests > 32) throw Error('[resource_limit] Network fixture query budget exceeded');
      if (!permit('network',String(url))) throw Error('[permission_denied] URL is not allowed by widget.json');
      const rule = (fixtures.fetch || []).find(item => item.url === url && (item.method || 'GET').toUpperCase() === method);
      if (!rule) {note('mock.http_missing','No offline HTTP fixture matched the requested URL and method.'); throw Error('[fixture.missing] No offline response for this URL');}
      if ('error' in rule) throw Error(rule.error);
      let body = typeof rule.body === 'string' ? rule.body : JSON.stringify(rule.body);
      return metadata ? {status:rule.status || 200,body,headers:copy(rule.headers || {})} : body;
    });
  }
  globalThis.fetch = globalThis.$fetch = url => http('GET',url,false);
  globalThis.$http = Object.freeze(Object.fromEntries(['get','post','put','patch','delete','head','getResponse'].map(name=>[name,(url)=>http(name==='getResponse'?'GET':name.toUpperCase(),url,name==='getResponse')])));
  globalThis.$dataSource = Object.freeze({request(){note('mock.unsupported_data_source','Native CLI data-source plugin execution was not validated.'); return asyncValue(()=>{throw Error('[fixture.unsupported] Native CLI data-source plugin execution is not available');});}});
  for (const [key,value] of Object.entries(fixtures.storage || {})) {
    if (!$storage.setString(key,String(value))) throw Error('[fixture.storage] Unable to seed isolated storage');
  }
  const RealDate=Date, fixed=1767268800000;
  function ValidationDate() { if (!new.target) return new RealDate(fixed).toString(); if (!arguments.length) return new RealDate(fixed); return new (Function.prototype.bind.apply(RealDate,[null].concat(Array.from(arguments))))(); }
  ValidationDate.prototype=RealDate.prototype; ValidationDate.now=()=>fixed; ValidationDate.UTC=RealDate.UTC; ValidationDate.parse=RealDate.parse; Date=ValidationDate;
  let seed=42; Math.random=()=>{seed=(seed*1103515245+12345)%2147483648; return seed/2147483648;};
})
