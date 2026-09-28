// Postman-compatible script sandbox. Evaluated once per script run, before the user script.
// Natives provided by Swift: __native.log, __native.requireSource, __native.sendRequest,
// __native.setTimer, __native.clearTimer, __native.dynamicVariable, __native.uuid.
(function (global) {
  'use strict';
  var input = __input;
  var native = __native;

  // ---------- helpers ----------
  function isObject(v) { return v !== null && typeof v === 'object'; }
  function stringify(value) {
    if (typeof value === 'string') return value;
    if (value === undefined) return 'undefined';
    if (typeof value === 'function') return value.toString();
    var seen = [];
    try {
      return JSON.stringify(value, function (k, v) {
        if (isObject(v)) { if (seen.indexOf(v) >= 0) return '[Circular]'; seen.push(v); }
        if (typeof v === 'function') return '[Function]';
        if (v === undefined) return null;
        return v;
      }, 2);
    } catch (e) { return String(value); }
  }
  function toStoredString(value) {
    if (value === undefined || value === null) return '';
    if (typeof value === 'string') return value;
    if (isObject(value)) return JSON.stringify(value);
    return String(value);
  }

  // ---------- console ----------
  function makeLogger(level) {
    return function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) parts.push(stringify(arguments[i]));
      native.log(level, parts.join(' '));
    };
  }
  global.console = { log: makeLogger('log'), info: makeLogger('info'), warn: makeLogger('warn'), error: makeLogger('error'), debug: makeLogger('debug') };

  // ---------- timers ----------
  var timerCallbacks = {};
  var nextTimerID = 1;
  global.setTimeout = function (fn, ms) {
    var id = nextTimerID++;
    var args = Array.prototype.slice.call(arguments, 2);
    timerCallbacks[id] = function () { delete timerCallbacks[id]; fn.apply(null, args); };
    native.setTimer(id, Number(ms) || 0);
    return id;
  };
  global.setInterval = function (fn, ms) {
    var id = nextTimerID++;
    timerCallbacks[id] = function () { native.setTimer(id, Number(ms) || 0); fn(); };
    native.setTimer(id, Number(ms) || 0);
    return id;
  };
  global.clearTimeout = global.clearInterval = function (id) { delete timerCallbacks[id]; native.clearTimer(id); };
  global.__fireTimer = function (id) { var cb = timerCallbacks[id]; if (cb) cb(); };

  // ---------- base64 ----------
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
  global.btoa = function (input) {
    var str = String(input), output = '';
    for (var block, charCode, idx = 0, map = chars; str.charAt(idx | 0) || (map = '=', idx % 1); output += map.charAt(63 & block >> 8 - idx % 1 * 8)) {
      charCode = str.charCodeAt(idx += 3 / 4);
      if (charCode > 0xFF) throw new Error("btoa: character out of range");
      block = block << 8 | charCode;
    }
    return output;
  };
  global.atob = function (input) {
    var str = String(input).replace(/[=]+$/, ''), output = '';
    for (var bc = 0, bs, buffer, idx = 0; buffer = str.charAt(idx++); ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4) ? output += String.fromCharCode(255 & bs >> (-2 * bc & 6)) : 0) {
      buffer = chars.indexOf(buffer);
    }
    return output;
  };

  // ---------- require ----------
  var moduleCache = {};
  var builtins = {
    uuid: function () { return { v4: function () { return native.uuid(); } }; },
    atob: function () { return global.atob; },
    btoa: function () { return global.btoa; }
  };
  global.require = function (name) {
    if (moduleCache[name]) return moduleCache[name];
    if (builtins[name]) return (moduleCache[name] = builtins[name]());
    var source = native.requireSource(name);
    if (typeof source !== 'string') throw new Error("Cannot find module '" + name + "'");
    var module = { exports: {} };
    // Like Node, expose partial exports during loading so cycles (e.g. lodash reading `root._`) terminate.
    moduleCache[name] = module.exports;
    var factory = new Function('module', 'exports', 'define', 'window', 'self', source + '\n//# sourceURL=' + name + '.js');
    try {
      factory.call(module.exports, module, module.exports, undefined, undefined, undefined);
    } catch (e) {
      delete moduleCache[name];
      throw e;
    }
    return (moduleCache[name] = module.exports);
  };
  Object.defineProperty(global, '_', { configurable: true, get: function () { return global.require('lodash'); } });
  Object.defineProperty(global, 'CryptoJS', { configurable: true, get: function () { return global.require('crypto-js'); } });
  Object.defineProperty(global, 'moment', { configurable: true, get: function () { return global.require('moment'); } });

  // ---------- variables ----------
  function Scope(name, entries) {
    this._name = name;
    this._values = new Map(entries || []);
  }
  Scope.prototype.get = function (key) { return this._values.has(key) ? this._values.get(key) : undefined; };
  Scope.prototype.has = function (key) { return this._values.has(key); };
  Scope.prototype.set = function (key, value) { this._values.set(String(key), value); };
  Scope.prototype.unset = function (key) { this._values.delete(key); };
  Scope.prototype.clear = function () { this._values.clear(); };
  Scope.prototype.toObject = function () { var o = {}; this._values.forEach(function (v, k) { o[k] = v; }); return o; };
  Scope.prototype.replaceIn = function (template) { return replaceIn(template); };
  Scope.prototype._entries = function () { var out = []; this._values.forEach(function (v, k) { out.push([k, toStoredString(v)]); }); return out; };

  var scopes = {
    globals: new Scope('globals', input.variables.globals),
    collectionVariables: new Scope('collection', input.variables.collection),
    environment: new Scope('environment', input.variables.environment),
    iterationData: new Scope('data', input.variables.data),
    local: new Scope('local', input.variables.local)
  };
  var precedence = [scopes.local, scopes.iterationData, scopes.environment, scopes.collectionVariables, scopes.globals];

  function lookup(key) {
    for (var i = 0; i < precedence.length; i++) if (precedence[i].has(key)) return precedence[i].get(key);
    return undefined;
  }
  function replaceIn(template) {
    if (typeof template !== 'string') return template;
    var current = template;
    for (var depth = 0; depth < 10; depth++) {
      var next = current.replace(/\{\{([^{}]+)\}\}/g, function (match, name) {
        name = name.trim();
        var value = lookup(name);
        if (value === undefined && name.charAt(0) === '$') value = native.dynamicVariable(name);
        return value === undefined || value === null ? match : toStoredString(value);
      });
      if (next === current) break;
      current = next;
    }
    return current;
  }
  var variables = {
    get: function (key) { return lookup(key); },
    has: function (key) { return lookup(key) !== undefined; },
    set: function (key, value) { scopes.local.set(key, value); },
    unset: function (key) { scopes.local.unset(key); },
    toObject: function () { var o = {}; for (var i = precedence.length - 1; i >= 0; i--) Object.assign(o, precedence[i].toObject()); return o; },
    replaceIn: replaceIn
  };

  // ---------- property lists (headers, query, form fields) ----------
  function PropertyList(items) { this._items = (items || []).map(function (i) { return { key: i.key, value: i.value, disabled: !!i.disabled }; }); }
  PropertyList.prototype._find = function (key) {
    var lower = String(key).toLowerCase();
    for (var i = 0; i < this._items.length; i++) if (String(this._items[i].key).toLowerCase() === lower && !this._items[i].disabled) return this._items[i];
    return undefined;
  };
  PropertyList.prototype.get = function (key) { var item = this._find(key); return item ? item.value : undefined; };
  PropertyList.prototype.one = function (key) { return this._find(key); };
  PropertyList.prototype.has = function (key, value) { var item = this._find(key); return !!item && (value === undefined || item.value === value); };
  PropertyList.prototype.add = function (item) { this._items.push({ key: item.key, value: toStoredString(item.value), disabled: !!item.disabled }); };
  PropertyList.prototype.append = PropertyList.prototype.add;
  PropertyList.prototype.upsert = function (item) {
    var existing = this._find(item.key);
    if (existing) existing.value = toStoredString(item.value); else this.add(item);
  };
  PropertyList.prototype.remove = function (predicate) {
    var fn = typeof predicate === 'function' ? predicate : function (i) { return String(i.key).toLowerCase() === String(predicate).toLowerCase(); };
    this._items = this._items.filter(function (i) { return !fn(i); });
  };
  PropertyList.prototype.clear = function () { this._items = []; };
  PropertyList.prototype.all = function () { return this._items.filter(function (i) { return !i.disabled; }); };
  PropertyList.prototype.each = function (fn) { this.all().forEach(fn); };
  PropertyList.prototype.map = function (fn) { return this.all().map(fn); };
  PropertyList.prototype.filter = function (fn) { return this.all().filter(fn); };
  PropertyList.prototype.count = function () { return this.all().length; };
  PropertyList.prototype.toObject = function () { var o = {}; this.all().forEach(function (i) { o[i.key] = i.value; }); return o; };
  PropertyList.prototype.toJSON = function () { return this._items; };

  // ---------- URL ----------
  function Url(raw) { this.update(raw); }
  Url.prototype.update = function (raw) {
    raw = String(raw || '');
    var hashIndex = raw.indexOf('#');
    this.hash = hashIndex >= 0 ? raw.slice(hashIndex + 1) : undefined;
    if (hashIndex >= 0) raw = raw.slice(0, hashIndex);
    var queryIndex = raw.indexOf('?');
    var query = queryIndex >= 0 ? raw.slice(queryIndex + 1) : '';
    var base = queryIndex >= 0 ? raw.slice(0, queryIndex) : raw;
    var scheme = base.indexOf('://');
    this.protocol = scheme >= 0 ? base.slice(0, scheme) : undefined;
    var rest = scheme >= 0 ? base.slice(scheme + 3) : base;
    var slash = rest.indexOf('/');
    var hostPort = slash >= 0 ? rest.slice(0, slash) : rest;
    var colon = hostPort.lastIndexOf(':');
    if (colon >= 0 && /^\d+$/.test(hostPort.slice(colon + 1))) { this.port = hostPort.slice(colon + 1); hostPort = hostPort.slice(0, colon); } else { this.port = undefined; }
    this.host = hostPort ? hostPort.split('.') : [];
    this.path = slash >= 0 ? rest.slice(slash + 1).split('/') : [];
    this.query = new PropertyList(query ? query.split('&').filter(Boolean).map(function (pair) {
      var eq = pair.indexOf('=');
      return eq >= 0 ? { key: pair.slice(0, eq), value: pair.slice(eq + 1) } : { key: pair, value: null };
    }) : []);
  };
  Url.prototype.getHost = function () { return this.host.join('.'); };
  Url.prototype.getPath = function () { return '/' + this.path.join('/'); };
  Url.prototype.getQueryString = function () {
    return this.query.all().map(function (q) { return q.value === null || q.value === undefined ? q.key : q.key + '=' + q.value; }).join('&');
  };
  Url.prototype.getPathWithQuery = function () { var q = this.getQueryString(); return this.getPath() + (q ? '?' + q : ''); };
  Url.prototype.getRemote = function () { return this.getHost() + (this.port ? ':' + this.port : ''); };
  Url.prototype.addQueryParams = function (params) { var self = this; (Array.isArray(params) ? params : [params]).forEach(function (p) { self.query.add(p); }); };
  Url.prototype.removeQueryParams = function (keys) { var self = this; (Array.isArray(keys) ? keys : [keys]).forEach(function (k) { self.query.remove(typeof k === 'string' ? k : k.key); }); };
  Url.prototype.toString = function () {
    var out = (this.protocol ? this.protocol + '://' : '') + this.getRemote() + (this.path.length ? '/' + this.path.join('/') : '');
    var q = this.getQueryString();
    if (q) out += '?' + q;
    if (this.hash !== undefined) out += '#' + this.hash;
    return out;
  };
  Url.prototype.toJSON = function () { return this.toString(); };

  // ---------- request ----------
  function makeRequest(spec) {
    var body = spec.body || { mode: 'none' };
    var request = {
      id: input.info.requestId,
      name: input.info.requestName,
      method: spec.method,
      url: new Url(spec.url),
      headers: new PropertyList(spec.headers),
      body: {
        mode: body.mode,
        raw: body.raw,
        urlencoded: new PropertyList(body.urlencoded),
        formdata: new PropertyList(body.formdata),
        graphql: body.graphql,
        update: function (value) {
          if (typeof value === 'string') { this.mode = 'raw'; this.raw = value; }
          else if (value && value.mode) { Object.assign(this, value); }
        },
        toString: function () { return this.mode === 'raw' ? (this.raw || '') : ''; },
        isEmpty: function () { return this.mode === 'none' || (this.mode === 'raw' && !this.raw); }
      },
      auth: spec.auth,
      addHeader: function (h) { this.headers.add(h); },
      removeHeader: function (k) { this.headers.remove(k); },
      upsertHeader: function (h) { this.headers.upsert(h); },
      addQueryParams: function (p) { this.url.addQueryParams(p); },
      removeQueryParams: function (p) { this.url.removeQueryParams(p); },
      toJSON: function () {
        return {
          method: this.method, url: this.url.toString(), headers: this.headers.toJSON(),
          body: { mode: this.body.mode, raw: this.body.raw, urlencoded: this.body.urlencoded.toJSON(), formdata: this.body.formdata.toJSON(), graphql: this.body.graphql }
        };
      }
    };
    return request;
  }

  // ---------- response ----------
  function makeResponse(data) {
    if (!data) return undefined;
    var headers = new PropertyList(data.headers);
    var response = {
      code: data.code,
      status: data.status,
      headers: headers,
      responseTime: data.responseTime,
      responseSize: data.responseSize,
      cookies: new PropertyList((data.cookies || []).map(function (c) { return { key: c.name, value: c.value }; })),
      text: function () { return data.body; },
      json: function () { return JSON.parse(data.body); },
      reason: function () { return data.status; },
      size: function () { return { body: data.bodySize, header: data.responseSize - data.bodySize, total: data.responseSize }; },
      toJSON: function () { return { code: data.code, status: data.status, headers: headers.toJSON(), body: data.body, responseTime: data.responseTime }; }
    };
    response.to = responseAssertions(response, false);
    return response;
  }

  function assertionError(message) { var e = new Error(message); e.name = 'AssertionError'; return e; }
  function responseAssertions(response, negate) {
    function check(condition, message, negatedMessage) {
      if (negate ? condition : !condition) throw assertionError(negate ? negatedMessage : message);
    }
    function statusIn(lower, upper, label) {
      check(response.code >= lower && response.code < upper, 'expected response code to be ' + label + ' but found ' + response.code, 'expected response code not to be ' + label);
      return true;
    }
    var contentType = (response.headers.get('Content-Type') || '').toLowerCase();
    var have = {
      status: function (expected) {
        if (typeof expected === 'number') check(response.code === expected, 'expected response to have status code ' + expected + ' but got ' + response.code, 'expected response to not have status code ' + expected);
        else check(response.status === expected, "expected response to have status reason '" + expected + "' but got '" + response.status + "'", "expected response to not have status reason '" + expected + "'");
      },
      header: function (key, value) {
        var actual = response.headers.get(key);
        if (value === undefined) check(actual !== undefined, "expected response to have header '" + key + "'", "expected response to not have header '" + key + "'");
        else check(actual === value, "expected '" + key + "' header to be '" + value + "' but got '" + actual + "'", "expected '" + key + "' header to not be '" + value + "'");
      },
      body: function (expected) {
        var text = response.text();
        if (expected === undefined) check(text.length > 0, 'expected response to have content in body', 'expected response to not have content in body');
        else if (expected instanceof RegExp) check(expected.test(text), 'expected response body to match ' + expected, 'expected response body to not match ' + expected);
        else check(text === expected, 'expected response body to equal ' + JSON.stringify(expected), 'expected response body to not equal ' + JSON.stringify(expected));
      },
      jsonBody: function (path, value) {
        var json;
        try { json = response.json(); } catch (e) { check(false, 'expected response body to be a valid json', ''); return; }
        if (path === undefined) { check(true, '', 'expected response body to not be json'); return; }
        if (typeof path === 'object') { check(stringify(json) === stringify(path), 'expected response json to deep equal ' + stringify(path), 'expected response json to not deep equal'); return; }
        var target = json, parts = String(path).split('.');
        for (var i = 0; i < parts.length; i++) { if (target === undefined || target === null) break; target = target[parts[i]]; }
        if (arguments.length < 2) check(target !== undefined, "expected response json to have path '" + path + "'", "expected response json to not have path '" + path + "'");
        else check(stringify(target) === stringify(value), "expected '" + path + "' to equal " + stringify(value) + ' but got ' + stringify(target), "expected '" + path + "' to not equal " + stringify(value));
      },
      responseTime: {
        below: function (ms) { check(response.responseTime < ms, 'expected response time ' + response.responseTime + 'ms to be below ' + ms + 'ms', ''); },
        above: function (ms) { check(response.responseTime > ms, 'expected response time ' + response.responseTime + 'ms to be above ' + ms + 'ms', ''); }
      }
    };
    var assertions = {
      have: have,
      get not() { return responseAssertions(response, !negate); }
    };
    assertions.be = {
      get ok() { return statusIn(200, 300, 'ok (2xx)'); },
      get success() { return statusIn(200, 300, 'success (2xx)'); },
      get info() { return statusIn(100, 200, 'informational (1xx)'); },
      get redirection() { return statusIn(300, 400, 'redirection (3xx)'); },
      get clientError() { return statusIn(400, 500, 'client error (4xx)'); },
      get serverError() { return statusIn(500, 600, 'server error (5xx)'); },
      get error() { return statusIn(400, 600, 'error (4xx or 5xx)'); },
      get accepted() { return statusIn(202, 203, 'accepted (202)'); },
      get badRequest() { return statusIn(400, 401, 'bad request (400)'); },
      get unauthorized() { return statusIn(401, 402, 'unauthorized (401)'); },
      get forbidden() { return statusIn(403, 404, 'forbidden (403)'); },
      get notFound() { return statusIn(404, 405, 'not found (404)'); },
      get rateLimited() { return statusIn(429, 430, 'rate limited (429)'); },
      get json() { check(contentType.indexOf('json') >= 0, "expected content-type to be json but got '" + contentType + "'", 'expected content-type to not be json'); return true; },
      get html() { check(contentType.indexOf('html') >= 0, "expected content-type to be html but got '" + contentType + "'", 'expected content-type to not be html'); return true; },
      get xml() { check(contentType.indexOf('xml') >= 0, "expected content-type to be xml but got '" + contentType + "'", 'expected content-type to not be xml'); return true; },
      withBody: true
    };
    return assertions;
  }

  // ---------- tests ----------
  var testResults = [];
  var pendingTests = [];
  function recordTest(name, fn) {
    var result = { name: String(name), passed: true, skipped: false, error: null };
    testResults.push(result);
    try {
      var value = fn && fn();
      if (value && typeof value.then === 'function') {
        pendingTests.push(value.then(function () {}, function (e) { result.passed = false; result.error = e && e.message ? e.message : String(e); }));
      }
    } catch (e) {
      result.passed = false;
      result.error = e && e.message ? e.message : String(e);
    }
    return pm;
  }
  recordTest.skip = function (name) { testResults.push({ name: String(name), passed: true, skipped: true, error: null }); return pm; };
  recordTest.index = function () { return testResults.length; };

  // ---------- sendRequest ----------
  var requestCallbacks = {};
  var nextRequestID = 1;
  function normalizeRequest(req) {
    if (typeof req === 'string') return { url: req, method: 'GET', headers: [], body: null };
    var headers = [];
    var header = req.header || req.headers;
    if (Array.isArray(header)) headers = header.map(function (h) { return { key: h.key, value: toStoredString(h.value) }; });
    else if (header instanceof PropertyList) headers = header.all();
    else if (isObject(header)) headers = Object.keys(header).map(function (k) { return { key: k, value: toStoredString(header[k]) }; });
    var body = null;
    if (req.body) {
      if (typeof req.body === 'string') body = { mode: 'raw', raw: req.body };
      else body = { mode: req.body.mode, raw: isObject(req.body.raw) ? JSON.stringify(req.body.raw) : req.body.raw, urlencoded: req.body.urlencoded, formdata: req.body.formdata, graphql: req.body.graphql };
    }
    return { url: String(req.url), method: (req.method || 'GET').toUpperCase(), headers: headers, body: body };
  }
  function sendRequest(req, callback) {
    var id = nextRequestID++;
    var promise = new Promise(function (resolve, reject) {
      requestCallbacks[id] = function (error, data) {
        delete requestCallbacks[id];
        var response = error ? null : makeResponse(data);
        if (callback) { try { callback(error ? new Error(error) : null, response); } catch (e) { console.error(e && e.message ? e.message : String(e)); } }
        if (error) reject(new Error(error)); else resolve(response);
      };
    });
    if (callback) promise.catch(function () {});
    native.sendRequest(id, JSON.stringify(normalizeRequest(req)));
    return promise;
  }
  global.__completeRequest = function (id, error, data) { var cb = requestCallbacks[id]; if (cb) cb(error, data); };

  // ---------- execution control ----------
  var execution = { nextRequest: undefined, nextRequestSet: false, skipRequest: false };
  function setNextRequest(name) { execution.nextRequest = name; execution.nextRequestSet = true; }

  // ---------- pm ----------
  var request = makeRequest(input.request);
  var response = makeResponse(input.response);
  var visualizer = null;
  var pm = {
    info: input.info,
    globals: scopes.globals,
    collectionVariables: scopes.collectionVariables,
    environment: scopes.environment,
    iterationData: scopes.iterationData,
    variables: variables,
    request: request,
    response: response,
    cookies: new PropertyList((input.cookies || []).map(function (c) { return { key: c.name, value: c.value }; })),
    test: recordTest,
    expect: function () { var chai = global.require('chai'); return chai.expect.apply(chai, arguments); },
    sendRequest: sendRequest,
    execution: {
      setNextRequest: setNextRequest,
      skipRequest: function () { execution.skipRequest = true; },
      location: [input.info.requestName]
    },
    visualizer: { set: function (template, data) { visualizer = { template: String(template), data: data === undefined ? null : data }; }, clear: function () { visualizer = null; } },
    require: global.require
  };
  pm.environment.name = input.info.environmentName;
  pm.cookies.jar = function () { return { get: function (url, name, cb) { cb(null, pm.cookies.get(name)); }, getAll: function (url, cb) { cb(null, pm.cookies.all()); } }; };
  global.pm = pm;

  // ---------- legacy postman / globals ----------
  global.postman = {
    setNextRequest: setNextRequest,
    setEnvironmentVariable: function (k, v) { scopes.environment.set(k, v); },
    getEnvironmentVariable: function (k) { return scopes.environment.get(k); },
    clearEnvironmentVariable: function (k) { scopes.environment.unset(k); },
    clearEnvironmentVariables: function () { scopes.environment.clear(); },
    setGlobalVariable: function (k, v) { scopes.globals.set(k, v); },
    getGlobalVariable: function (k) { return scopes.globals.get(k); },
    clearGlobalVariable: function (k) { scopes.globals.unset(k); },
    clearGlobalVariables: function () { scopes.globals.clear(); },
    getResponseHeader: function (k) { return response ? response.headers.get(k) : undefined; }
  };
  global.tests = {};
  global.environment = scopes.environment.toObject();
  global.globals = scopes.globals.toObject();
  global.data = scopes.iterationData.toObject();
  global.request = { url: request.url.toString(), method: request.method, headers: request.headers.toObject(), data: request.body.raw, name: request.name };
  if (response) {
    global.responseBody = response.text();
    global.responseCode = { code: response.code, name: response.status };
    global.responseHeaders = response.headers.toObject();
    global.responseTime = response.responseTime;
    global.responseCookies = response.cookies.all().map(function (c) { return { name: c.key, value: c.value }; });
  }
  global.xml2Json = function () { throw new Error('xml2Json is not supported'); };

  // ---------- output ----------
  global.__pendingTests = function () { return pendingTests.length ? Promise.all(pendingTests) : null; };
  global.__collectOutput = function () {
    Object.keys(global.tests).forEach(function (name) {
      testResults.push({ name: name, passed: !!global.tests[name], skipped: false, error: global.tests[name] ? null : 'Legacy test failed' });
    });
    return JSON.stringify({
      variables: {
        globals: scopes.globals._entries(),
        collection: scopes.collectionVariables._entries(),
        environment: scopes.environment._entries(),
        local: scopes.local._entries()
      },
      request: request.toJSON(),
      tests: testResults,
      nextRequestSet: execution.nextRequestSet,
      nextRequest: execution.nextRequest === undefined ? null : execution.nextRequest,
      skipRequest: execution.skipRequest,
      visualizer: visualizer ? { template: visualizer.template, data: JSON.stringify(visualizer.data) } : null
    });
  };
})(this);
