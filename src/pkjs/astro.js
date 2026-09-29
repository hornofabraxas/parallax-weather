// Sun and moon for the watch face. Standard low-precision astronomy (Meeus, "Astronomical
// Algorithms"): good to about a minute for the sun events and under a degree for the moon phase,
// far finer than one pixel of sun travel or one step of the terminator.
'use strict';

var RAD = Math.PI / 180;
var DAY_MS = 86400000;
var J2000 = 2451545.0;

function julian(ms) { return ms / DAY_MS + 2440587.5; }
function fromJulian(j) { return (j - 2440587.5) * DAY_MS; }
function norm360(a) { a %= 360; return a < 0 ? a + 360 : a; }

// Sun's apparent ecliptic longitude and declination (degrees), and the equation of time (minutes).
function sunCoords(jd) {
  var T = (jd - J2000) / 36525;
  var L0 = norm360(280.46646 + T * (36000.76983 + T * 0.0003032));
  var M = norm360(357.52911 + T * (35999.05029 - 0.0001537 * T));
  var e = 0.016708634 - T * (0.000042037 + 0.0000001267 * T);
  var C = (1.914602 - T * (0.004817 + 0.000014 * T)) * Math.sin(M * RAD) +
          (0.019993 - 0.000101 * T) * Math.sin(2 * M * RAD) + 0.000289 * Math.sin(3 * M * RAD);
  var omega = 125.04 - 1934.136 * T;
  var lambda = L0 + C - 0.00569 - 0.00478 * Math.sin(omega * RAD);
  var eps = 23.4392911 - T * 0.0130042 + 0.00256 * Math.cos(omega * RAD);
  var dec = Math.asin(Math.sin(eps * RAD) * Math.sin(lambda * RAD)) / RAD;
  var y = Math.pow(Math.tan(eps * RAD / 2), 2);
  var eot = 4 / RAD * (y * Math.sin(2 * L0 * RAD) - 2 * e * Math.sin(M * RAD) +
            4 * e * y * Math.sin(M * RAD) * Math.cos(2 * L0 * RAD) -
            0.5 * y * y * Math.sin(4 * L0 * RAD) - 1.25 * e * e * Math.sin(2 * M * RAD));
  return { lambda: norm360(lambda), dec: dec, eot: eot };
}

// Solar noon (ms) for the UTC calendar day containing dayMs, at longitude lon (east positive).
function solarNoon(dayMs, lon) {
  var d0 = Math.floor(dayMs / DAY_MS) * DAY_MS;
  var noon = d0 + (720 - 4 * lon) * 60000;
  for (var i = 0; i < 2; i++) noon = d0 + (720 - 4 * lon - sunCoords(julian(noon)).eot) * 60000;
  return noon;
}

// Time (ms) the sun crosses altitude alt (degrees) around noon; side -1 rising, +1 setting.
// null when it never does that day.
function crossing(noon, lat, alt, side) {
  var t = noon;
  for (var i = 0; i < 3; i++) {
    var dec = sunCoords(julian(t)).dec;
    var c = (Math.sin(alt * RAD) - Math.sin(lat * RAD) * Math.sin(dec * RAD)) /
            (Math.cos(lat * RAD) * Math.cos(dec * RAD));
    if (c < -1 || c > 1) return null;
    t = noon + side * Math.acos(c) / RAD / 15 * 3600000;
  }
  return t;
}

// The seven SUN_TIMES events for the local day containing dayMs (seconds, 0 = does not happen),
// and that day's peak elevation. The 10 degree threshold drops to half the peak when the sun
// stays under 20 degrees (spec "Day face").
function sunDay(dayMs, lat, lon) {
  var noon = solarNoon(dayMs, lon);
  var dec = sunCoords(julian(noon)).dec;
  var peak = 90 - Math.abs(lat - dec);
  var high = peak < 20 ? peak / 2 : 10;
  function s(t) { return t === null ? 0 : Math.round(t / 1000); }
  return {
    times: [
      s(crossing(noon, lat, -6, -1)), s(crossing(noon, lat, high, -1)), s(crossing(noon, lat, -0.833, -1)),
      peak > -0.833 ? Math.round(noon / 1000) : 0,
      s(crossing(noon, lat, -0.833, 1)), s(crossing(noon, lat, high, 1)), s(crossing(noon, lat, -6, 1))
    ],
    peak: Math.round(peak)
  };
}

// Moon phase as the elongation of the moon from the sun: 0 new, 90 first quarter, 180 full.
function moonPhase(ms) {
  var jd = julian(ms), T = (jd - J2000) / 36525;
  var Lp = 218.3164477 + 481267.88123421 * T;
  var D = 297.8501921 + 445267.1114034 * T;
  var M = 357.5291092 + 35999.0502909 * T;
  var Mp = 134.9633964 + 477198.8675055 * T;
  var F = 93.2720950 + 483202.0175233 * T;
  function s(a) { return Math.sin(norm360(a) * RAD); }
  var lambdaMoon = Lp + 6.288774 * s(Mp) + 1.274027 * s(2 * D - Mp) + 0.658314 * s(2 * D) +
    0.213618 * s(2 * Mp) - 0.185116 * s(M) - 0.114332 * s(2 * F) + 0.058793 * s(2 * D - 2 * Mp) +
    0.057066 * s(2 * D - M - Mp) + 0.053322 * s(2 * D + Mp) + 0.045758 * s(2 * D - M) -
    0.040923 * s(M - Mp) - 0.034720 * s(D) - 0.030383 * s(M + Mp);
  return norm360(lambdaMoon - sunCoords(jd).lambda);
}

module.exports = { sunDay: sunDay, moonPhase: moonPhase, solarNoon: solarNoon };
