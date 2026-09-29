// Node tests for the phone side (src/pkjs). Run: node tools/test/phone.test.js
'use strict';
var assert = require('assert');
var store = {};
global.localStorage = {
  getItem: function (k) { return k in store ? store[k] : null; },
  setItem: function (k, v) { store[k] = String(v); }
};
var listeners = {};
global.Pebble = { addEventListener: function (n, f) { listeners[n] = f; }, sendAppMessage: function () {} };

var astro = require('../../src/pkjs/astro');
var config = require('../../src/pkjs/config');
var index = require('../../src/pkjs/index');
var n = 0;
function check(name, f) { f(); n++; }

check('WMO mapping', function () {
  var want = { 0: 0, 1: 0, 2: 1, 3: 2, 45: 6, 48: 6, 51: 3, 67: 3, 80: 3, 82: 3, 71: 4, 77: 4, 85: 4, 86: 4, 95: 5, 99: 5, 4: 2 };
  Object.keys(want).forEach(function (c) { assert.strictEqual(index.weatherState(+c), want[c], 'code ' + c); });
});

check('Denver sun times, 2026-09-28', function () {
  var r = astro.sunDay(Date.UTC(2026, 8, 28), 39.74, -104.99);
  function mdt(t) { var d = new Date((t - 6 * 3600) * 1000); return d.getUTCHours() * 60 + d.getUTCMinutes(); }
  // published values (MDT, timeanddate.com): sunrise 06:53, sunset 18:46, civil dawn 06:26, civil dusk 19:13
  assert(Math.abs(mdt(r.times[2]) - (6 * 60 + 53)) <= 5, 'sunrise ' + mdt(r.times[2]));
  assert(Math.abs(mdt(r.times[4]) - (18 * 60 + 46)) <= 5, 'sunset ' + mdt(r.times[4]));
  assert(Math.abs(mdt(r.times[0]) - (6 * 60 + 26)) <= 5, 'dawn ' + mdt(r.times[0]));
  assert(Math.abs(mdt(r.times[6]) - (19 * 60 + 13)) <= 5, 'dusk ' + mdt(r.times[6]));
  for (var i = 1; i < 7; i++) if (i !== 2 && i !== 5) assert(r.times[i] > r.times[i - 1], 'order ' + i);
  assert(r.peak >= 47 && r.peak <= 50, 'peak ' + r.peak);  // 90 - 39.74 + declination (about -2.1)
});

check('polar cases', function () {
  var night = astro.sunDay(Date.UTC(2026, 11, 21), 78.2, 15.6);  // Longyearbyen: sun never above -6
  assert.deepStrictEqual(night.times, [0, 0, 0, 0, 0, 0, 0]);
  var day = astro.sunDay(Date.UTC(2026, 5, 21), 69.65, 18.96);   // Tromso: midnight sun
  assert(day.times[0] === 0 && day.times[2] === 0 && day.times[1] > 0 && day.times[5] > 0);
});

check('moon phase at every 2026 full moon', function () {
  // published instants, UTC (the list verified in Dragon-Watch/test/moon_test.c)
  var FULL = [[1, 3, 10, 3], [2, 1, 22, 9], [3, 3, 11, 38], [4, 2, 2, 13], [5, 1, 17, 24], [5, 31, 8, 46],
              [6, 29, 23, 57], [7, 29, 14, 36], [8, 28, 4, 18], [9, 26, 16, 48], [10, 26, 4, 11],
              [11, 24, 14, 53], [12, 24, 1, 28]];
  FULL.forEach(function (f) {
    var p = astro.moonPhase(Date.UTC(2026, f[0] - 1, f[1], f[2], f[3]));
    assert(Math.abs(p - 180) < 1.0, 'full moon ' + f.join('/') + ' phase ' + p.toFixed(2));
  });
});

check('defaults on a fresh install', function () {
  var d = config.load();  // nothing saved yet
  assert(d.bgDay === 1 && d.border === 1 && d.bgNight === 0 && d.tilt === 1 && d.refresh === 30 &&
    d.locationMode === 'auto', JSON.stringify(d));
  // the watch starts with the same values (s_in in src/c/main.c) until the phone sends them
  assert.deepStrictEqual(config.toWatch(d), { CFG_BORDER: 1, CFG_SKY: 0, CFG_TILT: 1, CFG_REFRESH: 30, CFG_BG: 1 });
});

check('settings page shows the thumbnails for the watch', function () {
  var thumbs = require('../../src/pkjs/thumbs');
  var keys = Object.keys(thumbs.pt2);
  assert.deepStrictEqual(Object.keys(thumbs.round), keys, 'both sets have every option');
  var rect = config.page(config.load(), 'emery'), round = config.page(config.load(), 'gabbro');
  keys.forEach(function (k) {
    assert(rect.indexOf(thumbs.pt2[k]) >= 0 && rect.indexOf(thumbs.round[k]) < 0, 'PT2 page, ' + k);
    assert(round.indexOf(thumbs.round[k]) >= 0 && round.indexOf(thumbs.pt2[k]) < 0, 'Round 2 page, ' + k);
  });
  assert(round.indexOf('<body class="round">') >= 0 && rect.indexOf('<body class="round">') < 0);
  // no watch info (older app, or the tests): the PT2 set
  assert(config.url().indexOf(encodeURIComponent(thumbs.pt2.bgDay0)) >= 0);
  global.Pebble.getActiveWatchInfo = function () { return { platform: 'gabbro' }; };
  assert(config.url().indexOf(encodeURIComponent(thumbs.round.bgDay0)) >= 0);
  global.Pebble.getActiveWatchInfo = function () { return null; };  // watch out of reach: last one seen
  assert.strictEqual(config.watchPlatform(), 'gabbro');
  global.Pebble.getActiveWatchInfo = function () { return { platform: 'emery' }; };
  assert.strictEqual(config.watchPlatform(), 'emery');
  delete global.Pebble.getActiveWatchInfo;
});

check('settings round trip and validation', function () {
  var msg = config.save(encodeURIComponent(JSON.stringify({ border: '1', sky: '1', bgDay: '0', bgNight: '1', tilt: '0', refresh: '60', locationMode: 'manual', lat: '39.7', lon: '-105' })));
  assert.deepStrictEqual(msg, { CFG_BORDER: 1, CFG_SKY: 1, CFG_TILT: 0, CFG_REFRESH: 60, CFG_BG: 2 });
  var s = config.load();
  assert(s.locationMode === 'manual' && s.lat === 39.7 && s.lon === -105);
  msg = config.save(encodeURIComponent(JSON.stringify({ bgDay: '1', bgNight: '7', locationMode: 'auto' })));
  assert.strictEqual(msg.CFG_BG, 1, 'bad night value falls back to the moon');
  config.save(encodeURIComponent(JSON.stringify({ border: 'x', refresh: '7', locationMode: 'manual', lat: '', lon: '' })));
  s = config.load();
  assert(s.border === 0 && s.refresh === 30 && s.locationMode === 'auto', JSON.stringify(s));
  assert.strictEqual(config.save('CANCELLED'), null);
  assert.strictEqual(config.save(''), null);
  assert(config.url().indexOf('data:text/html') === 0);
  var html = decodeURIComponent(config.url());
  assert(html.indexOf('name="bgDay"') > 0 && html.indexOf('name="bgNight"') > 0 && html.indexOf('bgNight:v("bgNight")') > 0,
    'background choices are on the page and saved');
  var thumbs = require('../../src/pkjs/thumbs');
  ['pt2', 'round'].forEach(function (set) {
    Object.keys(thumbs[set]).forEach(function (k) {
      assert(/^data:image\/webp;base64,[A-Za-z0-9+\/=]+$/.test(thumbs[set][k]), 'thumbnail ' + set + ' ' + k);
    });
  });
  Object.keys(thumbs.pt2).forEach(function (k) {
    assert(html.indexOf(thumbs.pt2[k]) > 0, 'thumbnail ' + k + ' is on the page');
  });
  // every option shown as a picture has one: 2 day, 2 sky, 2 border, 2 night
  assert.strictEqual((html.match(/<img/g) || []).length, 8);
  function section(h, id) { var i = h.indexOf('id="' + id + '"'); return h.slice(i, h.indexOf('>', i)); }
  var auto = config.page(Object.assign(config.load(), { bgDay: 0, locationMode: 'auto' }));
  var wx = config.page(Object.assign(config.load(), { bgDay: 1, locationMode: 'manual', lat: 39.7, lon: -105 }));
  assert(section(auto, 'skySet').indexOf('hidden') < 0 && section(wx, 'skySet').indexOf('hidden') > 0,
    'sky style only with the sky background');
  assert(section(auto, 'coords').indexOf('hidden') > 0 && section(wx, 'coords').indexOf('hidden') < 0,
    'coordinates only in manual mode');
  assert(wx.indexOf('value="39.7"') > 0 && wx.indexOf('value="-105"') > 0, 'coordinates filled in');
  // the page script is assembled from fragments: it must still parse
  var js = auto.slice(auto.indexOf('<script>') + 8, auto.indexOf('</script>'));
  assert(js.length > 100);
  new Function(js);  // throws on a syntax error
  assert(wx.indexOf('inputmode') < 0, 'no decimal pad: iOS would lose the minus key');
  // a stored adaptive (1) or always (2) border from older versions is simply on
  localStorage.setItem('wcf-settings-v1', JSON.stringify({ border: 2 }));
  assert.strictEqual(config.load().border, 1);
  assert.strictEqual(config.toWatch(config.load()).CFG_BORDER, 1);
  assert(html.indexOf('Parallax Weather') > 0 && html.indexOf('Moonphase') > 0 && html.indexOf('<small') < 0);
});

check('sky message layout', function () {
  var m = index.skyMessage({ lat: -33.9, lon: 151.2 });
  assert.strictEqual(m.SUN_TIMES.length, 56);
  assert.strictEqual(m.HEMISPHERE, -1);
  assert(m.MOON_PHASE >= 0 && m.MOON_PHASE < 360);
});

check('sun day follows the phone clock, not the UTC date', function () {
  function noonLocal(tz, now, lon, wantHour) {
    process.env.TZ = tz;
    var d0 = index.sunDayStart(now, lon);
    var noon = require('../../src/pkjs/astro').solarNoon(d0, lon);
    var h = new Date(noon).getHours();
    assert.strictEqual(new Date(noon).getDate(), now.getDate(), tz + ' noon on the local date');
    assert(Math.abs(h - wantHour) <= 1, tz + ' noon hour ' + h);
  }
  noonLocal('Pacific/Apia', new Date(2026, 8, 29, 8, 0), -171.76, 12);
  noonLocal('America/Denver', new Date(2026, 8, 29, 8, 0), -104.99, 12);  // solar noon 12:50 daylight time
  noonLocal('Pacific/Kiritimati', new Date(2026, 8, 29, 8, 0), -157.4, 12);
  // phone in Tokyo, manual location in Denver: Denver's noon nearest Tokyo's noon (about 03:50)
  process.env.TZ = 'Asia/Tokyo';
  var now = new Date(2026, 8, 29, 2, 0), d0 = index.sunDayStart(now, -104.99);
  var noon = require('../../src/pkjs/astro').solarNoon(d0, -104.99);
  assert(Math.abs(noon - new Date(2026, 8, 29, 12).getTime()) < 9 * 3600000, 'nearest Denver noon');
  delete process.env.TZ;
});

console.log(n + ' phone checks passed');
