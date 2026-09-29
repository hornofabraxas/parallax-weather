// Phone side. The watch asks (REQUEST bitmask), the phone answers with a few integers.
// Weather: Open-Meteo, no API key. Sun and moon: astro.js. Settings: config.js.
'use strict';

var astro = require('./astro');
var config = require('./config');

var NEED_WEATHER = 1, NEED_SKY = 2;
var LOCATION_KEY = 'wcf-location-v1';
var LOCATION_MAX_AGE_MS = 30 * 60 * 1000;  // coarse: an older fix is the same forecast cell

function log(msg) { console.log('wcf: ' + msg); }

// WMO weather codes to the watch's weather states (spec "Weather states and textures").
var CLEAR = 0, PARTLY = 1, CLOUDY = 2, RAIN = 3, SNOW = 4, STORM = 5, FOG = 6;
function weatherState(code) {
  if (code === 0 || code === 1) return CLEAR;
  if (code === 2) return PARTLY;
  if (code === 3) return CLOUDY;
  if (code === 45 || code === 48) return FOG;
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) return RAIN;
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return SNOW;
  if (code >= 95 && code <= 99) return STORM;
  return CLOUDY;
}

function cachedLocation() {
  try { return JSON.parse(localStorage.getItem(LOCATION_KEY)); } catch (e) { return null; }
}

// Calls back once with {lat, lon} or null. Manual settings win; otherwise a coarse fix, falling
// back to the last one we had. A watchdog answers if the host never calls back.
function getLocation(cb) {
  var s = config.load();
  if (s.locationMode === 'manual' && isFinite(s.lat) && isFinite(s.lon)) return cb({ lat: s.lat, lon: s.lon });
  var last = cachedLocation(), called = false;
  function once(loc) {
    if (called) return;
    called = true;
    clearTimeout(watchdog);
    cb(loc);
  }
  var watchdog = setTimeout(function () { log('location timed out'); once(last); }, 30000);
  try {
    navigator.geolocation.getCurrentPosition(function (pos) {
      var loc = { lat: pos.coords.latitude, lon: pos.coords.longitude };
      try { localStorage.setItem(LOCATION_KEY, JSON.stringify(loc)); } catch (e) { /* keep going without the cache */ }
      once(loc);
    }, function (err) {
      log('location failed (' + (err && err.message) + '), using ' + (last ? 'last fix' : 'nothing'));
      once(last);
    }, { enableHighAccuracy: false, maximumAge: LOCATION_MAX_AGE_MS, timeout: 15000 });
  } catch (e) {
    log('no geolocation: ' + e.message);
    once(last);
  }
}

function fetchWeather(loc, cb) {
  var url = 'https://api.open-meteo.com/v1/forecast?latitude=' + loc.lat.toFixed(3) +
    '&longitude=' + loc.lon.toFixed(3) + '&current=weather_code&timeformat=unixtime';
  var xhr = new XMLHttpRequest();
  xhr.onload = function () {
    try {
      var cur = JSON.parse(xhr.responseText).current;
      if (typeof cur.weather_code !== 'number' || typeof cur.time !== 'number') throw new Error('no current weather');
      cb({ state: weatherState(cur.weather_code), time: cur.time, code: cur.weather_code });
    } catch (e) {
      log('weather parse failed: ' + e.message);
      cb(null);
    }
  };
  xhr.onerror = xhr.ontimeout = function () { log('weather request failed'); cb(null); };
  xhr.open('GET', url);
  xhr.timeout = 20000;
  xhr.send();
}

function int32Bytes(values) {
  var out = [];
  values.forEach(function (v) { for (var i = 0; i < 4; i++) out.push((v >>> (8 * i)) & 255); });
  return out;
}

// UTC midnight of the day whose solar noon at lon is nearest the phone's local noon today. Using
// the phone's calendar date as a UTC date picks the wrong day when the time zone is far from the
// longitude (Samoa, Kiritimati, a phone in Tokyo with a manual location in Denver).
function sunDayStart(now, lon) {
  var localNoon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12).getTime();
  return Math.round((localNoon - (720 - 4 * lon) * 60000) / 86400000) * 86400000;
}

// Sun times for the local day and the next, moon phase now, hemisphere.
function skyMessage(loc, now) {
  now = now || new Date();
  var d0 = sunDayStart(now, loc.lon);
  var today = astro.sunDay(d0, loc.lat, loc.lon), tomorrow = astro.sunDay(d0 + 86400000, loc.lat, loc.lon);
  return {
    SUN_TIMES: int32Bytes(today.times.concat(tomorrow.times)),
    SUN_PEAK: today.peak,
    MOON_PHASE: Math.round(astro.moonPhase(now.getTime())) % 360,
    MOON_TIME: Math.round(now.getTime() / 1000),
    HEMISPHERE: loc.lat < 0 ? -1 : 1
  };
}

// Where and in which time zone the watch's sun times were last computed. The spec sends sun times
// on a location change too, so a flight does not leave sunrise hours out until midnight.
var SKY_KEY = 'wcf-sky-origin-v1';
function skyMoved(loc) {
  var o;
  try { o = JSON.parse(localStorage.getItem(SKY_KEY)); } catch (e) { o = null; }
  if (!o) return true;
  var dLat = (loc.lat - o.lat) * 111, dLon = (loc.lon - o.lon) * 111 * Math.cos(loc.lat * Math.PI / 180);
  return dLat * dLat + dLon * dLon > 50 * 50 || o.tz !== new Date().getTimezoneOffset();
}
function skySent(loc) {
  try {
    localStorage.setItem(SKY_KEY, JSON.stringify({ lat: loc.lat, lon: loc.lon, tz: new Date().getTimezoneOffset() }));
  } catch (e) { /* next request just resends */ }
}

function send(msg, onOk) {
  var tries = 0;
  (function attempt() {
    tries++;
    Pebble.sendAppMessage(msg, function () {
      log('sent ' + Object.keys(msg).join(' '));
      if (onOk) onOk();
    }, function () {
      log('send failed (try ' + tries + ')');
      if (tries < 3) setTimeout(attempt, 2000);
    });
  })();
}

// One request at a time; a request arriving meanwhile is merged and run when this one finishes.
var busy = false, pending = 0;
function answer(need) {
  if (busy) { pending |= need; return; }
  busy = true;
  var finished = false;
  function finish(msg, loc, withSky) {
    if (finished) return;
    finished = true;
    clearTimeout(watchdog);
    if (msg && Object.keys(msg).length) send(msg, withSky ? function () { skySent(loc); } : null);
    busy = false;
    if (pending) {
      var next = pending;
      pending = 0;
      answer(next);
    }
  }
  var watchdog = setTimeout(function () { log('request timed out'); finish({ WX_FAILED: 1 }); }, 60000);
  try {
    getLocation(function (loc) {
      if (!loc) return finish({ WX_FAILED: 1 });
      var withSky = (need & NEED_SKY) || skyMoved(loc);
      var msg = withSky ? skyMessage(loc) : {};
      if (!(need & NEED_WEATHER)) return finish(msg, loc, withSky);
      fetchWeather(loc, function (wx) {
        if (wx) {
          msg.WX_STATE = wx.state;
          msg.WX_TIME = wx.time;
          log('weather code ' + wx.code + ' -> state ' + wx.state);
        } else {
          msg.WX_FAILED = 1;
        }
        finish(msg, loc, withSky);
      });
    });
  } catch (e) {
    log('request failed: ' + e.message);
    finish({ WX_FAILED: 1 });
  }
}

Pebble.addEventListener('ready', function () {
  log('ready');
  // settings ride along: the watch may have lost them (store version change, reinstall)
  var msg = config.toWatch(config.load());
  msg.READY = 1;
  send(msg);
});

Pebble.addEventListener('appmessage', function (e) {
  var need = e.payload.REQUEST;
  if (need) answer(need);
});

Pebble.addEventListener('showConfiguration', function () { Pebble.openURL(config.url()); });

Pebble.addEventListener('webviewclosed', function (e) {
  var msg = config.save(e && e.response);
  if (!msg) return;
  send(msg, function () { answer(NEED_WEATHER | NEED_SKY); });  // the location may have changed
});

module.exports = { weatherState: weatherState, skyMessage: skyMessage, sunDayStart: sunDayStart };
