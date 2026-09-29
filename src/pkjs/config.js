// Settings page (spec "Settings"): a self-contained page opened as a data: URL, so there is no
// hosting and no dependency. Values live in the phone's localStorage; the watch gets CFG_* keys.
'use strict';

var thumbs = require('./thumbs');

var KEY = 'wcf-settings-v1';
var DEFAULTS = { border: 1, sky: 0, bgDay: 1, bgNight: 0, tilt: 1, refresh: 30, locationMode: 'auto', lat: NaN, lon: NaN };

function load() {
  var s = {};
  try { s = JSON.parse(localStorage.getItem(KEY)) || {}; } catch (e) { s = {}; }
  var out = {};
  Object.keys(DEFAULTS).forEach(function (k) { out[k] = k in s && s[k] !== null ? s[k] : DEFAULTS[k]; });
  out.border = out.border ? 1 : 0;  // the old 1 (adaptive) and 2 (always) are both "on" now
  return out;
}

function toWatch(s) {
  // CFG_BG: bit 0 = weather as the day background, bit 1 = at night
  return { CFG_BORDER: s.border, CFG_SKY: s.sky, CFG_TILT: s.tilt, CFG_REFRESH: s.refresh, CFG_BG: s.bgDay | s.bgNight << 1 };
}

function clampInt(v, allowed, fallback) {
  v = parseInt(v, 10);
  return allowed.indexOf(v) >= 0 ? v : fallback;
}

// Parses the page's response, stores it, and returns the message for the watch (null if cancelled).
function save(response) {
  if (!response || response === 'CANCELLED') return null;
  var r;
  try { r = JSON.parse(decodeURIComponent(response)); } catch (e) { return null; }
  var s = {
    border: parseInt(r.border, 10) ? 1 : 0,  // any old nonzero (adaptive, always) is on
    sky: clampInt(r.sky, [0, 1], DEFAULTS.sky),
    bgDay: clampInt(r.bgDay, [0, 1], DEFAULTS.bgDay),
    bgNight: clampInt(r.bgNight, [0, 1], DEFAULTS.bgNight),
    tilt: clampInt(r.tilt, [0, 1], DEFAULTS.tilt),
    refresh: clampInt(r.refresh, [15, 30, 60], DEFAULTS.refresh),
    locationMode: r.locationMode === 'manual' ? 'manual' : 'auto',
    lat: parseFloat(r.lat),
    lon: parseFloat(r.lon)
  };
  if (!(s.lat >= -90 && s.lat <= 90 && s.lon >= -180 && s.lon <= 180)) {
    s.lat = NaN;
    s.lon = NaN;
    s.locationMode = 'auto';  // manual needs a valid position
  }
  localStorage.setItem(KEY, JSON.stringify(s));
  return toWatch(s);
}

function esc(v) { return String(v).replace(/[&<>"]/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; }); }

// Colours are the watch's own: black, the night border cyan, and the morning sky for the rule.
var CSS = [
  ':root{color-scheme:dark}',
  '*{box-sizing:border-box}',
  'body{margin:0;background:#000;color:#eee;font:16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;',
  '-webkit-text-size-adjust:100%}',
  'main{max-width:520px;margin:0 auto;padding:20px 16px 104px}',
  'header h1{margin:0;font-size:26px;font-weight:900;letter-spacing:-.01em}',
  '.rule{height:3px;margin:12px 0 6px;border-radius:2px;background:linear-gradient(90deg,#AAAAFF,#FFAAAA,#FFFFAA)}',
  'h2{margin:26px 0 10px;color:#aaa;font-size:12px;font-weight:700;letter-spacing:.12em;text-transform:uppercase}',
  '.set{background:#111;border:1px solid #222;border-radius:14px;padding:14px;margin:0 0 10px}',
  '.set[hidden]{display:none}',
  '.name{font-weight:650;margin:0 0 10px}',
  '.pick{display:grid;grid-template-columns:repeat(2,1fr);gap:10px}',
  '.pick label{position:relative;display:block;cursor:pointer;-webkit-tap-highlight-color:transparent}',
  'input.x{position:absolute;opacity:0;width:1px;height:1px;margin:0}',
  '.card{display:flex;flex-direction:column;align-items:center;padding:8px 6px 9px;border:2px solid #2a2a2a;',
  'border-radius:12px;background:#0a0a0a;transition:border-color .15s,box-shadow .15s}',
  '.card img{display:block;width:100%;max-width:112px;aspect-ratio:200/228;border-radius:6px;background:#000}',
  '.card img.crop{max-width:96px;aspect-ratio:1;image-rendering:pixelated}',
  '.round .card img{aspect-ratio:1;border-radius:50%}',
  '.round .card img.crop{border-radius:6px}',
  '.card b{margin-top:7px;font-size:14px;font-weight:650}',
  'input.x:checked+.card{border-color:#55FFFF;box-shadow:0 0 0 1px #55FFFF,0 0 14px rgba(85,255,255,.28)}',
  'input.x:checked+.card b{color:#55FFFF}',
  'input.x:focus+.card,input.x:focus+.seg{outline:2px solid #fff;outline-offset:2px}',
  'input.x:focus:not(:focus-visible)+.card,input.x:focus:not(:focus-visible)+.seg{outline:none}',
  '.segs{display:flex;background:#0a0a0a;border:1px solid #2a2a2a;border-radius:11px;padding:3px}',
  '.segs label{flex:1;position:relative}',
  '.seg{display:block;text-align:center;padding:8px 4px;border-radius:8px;font-size:15px;color:#bbb;cursor:pointer}',
  'input.x:checked+.seg{background:#55FFFF;color:#000;font-weight:650}',
  '.coords{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:12px}',
  '.coords[hidden]{display:none}',
  '.coords label{font-size:13px;color:#aaa}',
  '.coords input{display:block;width:100%;margin-top:4px;padding:9px 10px;font-size:16px;color:#eee;',
  'background:#000;border:1px solid #333;border-radius:9px}',
  '.coords input:focus{outline:none;border-color:#55FFFF}',
  '#err{color:#FF5555;font-size:14px;margin:10px 0 0}',
  '#err:empty{display:none}',
  '.bar{position:fixed;left:0;right:0;bottom:0;padding:14px 16px;padding-bottom:calc(14px + env(safe-area-inset-bottom));',
  'background:linear-gradient(transparent,#000 35%)}',
  '.bar button{display:block;width:100%;max-width:520px;margin:0 auto;padding:14px;font-size:17px;font-weight:700;',
  'color:#000;background:#55FFFF;border:0;border-radius:12px}',
  '.bar button:active{background:#AAFFFF}'
].join('');

// The save script, run in the page: collect the checked options, validate the coordinates,
// return to the Pebble app (or the emulator's return_to).
var SCRIPT = [
  'function v(n){var e=document.querySelector("input[name="+n+"]:checked");return e?e.value:null}',
  'function $(i){return document.getElementById(i)}',
  // Sky style only matters with the sky background; the coordinates only in manual mode
  'function sync(){$("skySet").hidden=v("bgDay")==="1";$("coords").hidden=v("locationMode")!=="manual";',
  '$("err").textContent=""}',
  'document.addEventListener("change",sync);',
  '$("save").onclick=function(){',
  'var r={border:v("border"),sky:v("sky"),bgDay:v("bgDay"),bgNight:v("bgNight"),tilt:v("tilt"),',
  'refresh:v("refresh"),locationMode:v("locationMode"),lat:$("lat").value,lon:$("lon").value};',
  'if(r.locationMode==="manual"){var la=parseFloat(r.lat),lo=parseFloat(r.lon);',
  'if(!(la>=-90&&la<=90&&lo>=-180&&lo<=180)){$("err").textContent=',
  '"Enter a latitude from -90 to 90 and a longitude from -180 to 180.";',
  '$(la>=-90&&la<=90?"lon":"lat").focus();return}}',
  'var m=(location.search+location.hash).match(/return_to=([^&]*)/);',
  'var to=m?decodeURIComponent(m[1]):"pebblejs://close#";',
  'location.href=to+encodeURIComponent(JSON.stringify(r))}'
].join('');

// Round 2 watches get the round thumbnail set and round frames on the page.
function isRound(platform) { return platform === 'gabbro'; }

// The watch's platform, remembered: with the watch briefly out of reach there is no watch info, and a
// Round 2 owner should still see round frames.
var PLATFORM_KEY = 'wcf-platform';
function watchPlatform() {
  var p = null;
  try {
    var w = Pebble.getActiveWatchInfo && Pebble.getActiveWatchInfo();
    p = w && w.platform;
  } catch (e) { p = null; }
  if (p) {
    localStorage.setItem(PLATFORM_KEY, p);
    return p;
  }
  return localStorage.getItem(PLATFORM_KEY) || 'emery';
}

function page(s, platform) {
  var round = isRound(platform), shots = round ? thumbs.round : thumbs.pt2;
  function input(name, value) {
    return '<input class="x" type="radio" name="' + name + '" value="' + value + '"' +
      (String(s[name]) === String(value) ? ' checked' : '') + '>';
  }
  // an option shown as its own screenshot: tap the picture to choose it
  function pick(name, value, thumb, title, crop) {
    return '<label>' + input(name, value) + '<span class="card"><img' + (crop ? ' class="crop"' : '') +
      ' src="' + shots[thumb] + '" alt=""><b>' + title + '</b></span></label>';
  }
  function seg(name, value, title) {
    return '<label>' + input(name, value) + '<span class="seg">' + title + '</span></label>';
  }
  function set(name, body, id, hidden) {
    return '<section class="set"' + (id ? ' id="' + id + '"' : '') + (hidden ? ' hidden' : '') + '>' +
      '<div class="name" aria-hidden="true">' + name + '</div>' + body + '</section>';
  }
  // a radio group named in full ("Day background"), since the card titles repeat across sections
  function group(cls, label, options) {
    return '<div class="' + cls + '" role="radiogroup" aria-label="' + label + '">' + options + '</div>';
  }
  var manual = s.locationMode === 'manual';
  return '<!doctype html><html><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' +
    '<title>Parallax Weather</title><style>' + CSS + '</style></head><body' + (round ? ' class="round"' : '') + '><main>' +
    '<header><h1>Parallax Weather</h1><div class="rule"></div></header>' +
    '<h2>Day</h2>' +
    set('Background', group('pick', 'Day background',
      pick('bgDay', 0, 'bgDay0', 'Sky') + pick('bgDay', 1, 'bgDay1', 'Weather'))) +
    set('Sky style', group('pick', 'Sky style',
      pick('sky', 0, 'sky0', 'Gradient') + pick('sky', 1, 'sky1', 'Solid')), 'skySet', String(s.bgDay) === '1') +
    set('Digit border', group('pick', 'Digit border by day',
      pick('border', 0, 'border0', 'Off', true) + pick('border', 1, 'border1', 'On', true))) +
    '<h2>Night</h2>' +
    set('Background', group('pick', 'Night background',
      pick('bgNight', 0, 'bgNight0', 'Moonphase') + pick('bgNight', 1, 'bgNight1', 'Weather'))) +
    '<h2>Motion</h2>' +
    set('Tilt effect', group('segs', 'Tilt effect', seg('tilt', 1, 'On') + seg('tilt', 0, 'Off'))) +
    '<h2>Weather</h2>' +
    set('Refresh', group('segs', 'Weather refresh', seg('refresh', 15, '15 min') + seg('refresh', 30, '30 min') +
      seg('refresh', 60, '60 min'))) +
    set('Location', group('segs', 'Location', seg('locationMode', 'auto', 'Automatic') +
      seg('locationMode', 'manual', 'Manual')) +
      '<div class="coords" id="coords"' + (manual ? '' : ' hidden') + '>' +
      '<label>Latitude<input type="number" step="any" id="lat" value="' +
      (isFinite(s.lat) ? esc(s.lat) : '') + '" placeholder="51.48"></label>' +
      '<label>Longitude<input type="number" step="any" id="lon" value="' +
      (isFinite(s.lon) ? esc(s.lon) : '') + '" placeholder="0.00"></label></div>' +
      '<p id="err"></p>') +
    '</main><div class="bar"><button id="save">Save</button></div><script>' + SCRIPT + '</script></body></html>';
}

function url() {
  return 'data:text/html;charset=utf-8,' + encodeURIComponent(page(load(), watchPlatform()));
}

module.exports = { load: load, save: save, url: url, toWatch: toWatch, page: page, watchPlatform: watchPlatform };
