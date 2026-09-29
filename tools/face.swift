import Foundation
import CoreGraphics
import CoreText
import ImageIO
import AppKit

// Renders Pebble Time 2 (emery, 200x228, 64-colour) mockups at 8x supersampling,
// then snaps every pixel to an exact Pebble colour with no dithering.
// Usage: face <mode: day|night|moon> <font> <out-prefix>
// PW / PH set another screen (Round 2: PW=260 PH=260 DIGIT_H=94); only the export mode is kept
// size-aware, the mockup modes assume PT2.

let ENV = ProcessInfo.processInfo.environment
let W = Int(ENV["PW"] ?? "200")!, H = Int(ENV["PH"] ?? "228")!, SS = 8
var TW = W, TH = H
var CLOUD_RAMP = [0x0055AA, 0x5555AA, 0xAAAAFF, 0xFFFFFF]
var ENVMX = 0
let HW = W * SS, HH = H * SS, N = HW * HH

func idx(_ h: Int) -> Int { (((h >> 16) & 255) / 85) * 16 + (((h >> 8) & 255) / 85) * 4 + (h & 255) / 85 }
func rgb(_ i: Int) -> (Double, Double, Double) { (Double(i / 16 * 85), Double(i / 4 % 4 * 85), Double(i % 4 * 85)) }

// ---------------- fonts ----------------
func makeFont(_ name: String, _ size: CGFloat) -> CTFont {
    switch name {
    case "SF-Heavy": return NSFont.systemFont(ofSize: size, weight: .heavy) as CTFont
    case "SF-Bold": return NSFont.systemFont(ofSize: size, weight: .bold) as CTFont
    case "SFRounded-Heavy", "SFRounded-Bold":
        let base = NSFont.systemFont(ofSize: size, weight: name.hasSuffix("Heavy") ? .heavy : .bold)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)!, size: size)! as CTFont
    default:
        if name.hasSuffix(".ttf") || name.hasSuffix(".otf") {   // a font file, e.g. fonts/InterDisplay-Black.ttf
            let data = try! Data(contentsOf: URL(fileURLWithPath: name)) as CFData
            return CTFontCreateWithFontDescriptor(CTFontManagerCreateFontDescriptorFromData(data)!, size, nil)
        }
        return CTFontCreateWithName(name as CFString, size, nil)
    }
}
func glyph(_ f: CTFont, _ ch: Character) -> CGGlyph {
    var u = Array(String(ch).utf16); var g = [CGGlyph](repeating: 0, count: u.count)
    CTFontGetGlyphsForCharacters(f, &u, &g, u.count); return g[0]
}
func bbox(_ f: CTFont, _ g: CGGlyph) -> CGRect { var gg = g; return CTFontGetBoundingRectsForGlyphs(f, .default, &gg, nil, 1) }
func advance(_ f: CTFont, _ g: CGGlyph) -> CGFloat { var gg = g; return CGFloat(CTFontGetAdvancesForGlyphs(f, .default, &gg, nil, 1)) }

// path for glyph whose origin (baseline-left) sits at screen px (x, baseline), y-down screen coords
func gpath(_ f: CTFont, _ g: CGGlyph, _ x: Double, _ baseline: Double) -> CGPath {
    var t = CGAffineTransform(translationX: CGFloat(x * Double(SS)), y: CGFloat(Double(HH) - baseline * Double(SS)))
    return CTFontCreatePathForGlyph(f, g, &t)!
}

func render(_ paths: [CGPath], stroke: CGFloat = 0) -> [UInt8] {
    let ctx = CGContext(data: nil, width: HW, height: HH, bitsPerComponent: 8, bytesPerRow: HW,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: HW, height: HH))
    ctx.setFillColor(gray: 1, alpha: 1); ctx.setStrokeColor(gray: 1, alpha: 1)
    for p in paths { ctx.addPath(p) }
    if stroke > 0 { ctx.setLineWidth(stroke); ctx.setLineJoin(.round); ctx.drawPath(using: .fillStroke) } else { ctx.fillPath() }
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: N)
    return Array(UnsafeBufferPointer(start: p, count: N))
}

func coverage(_ m: [UInt8]) -> [Double] {
    var out = [Double](repeating: 0, count: W * H)
    m.withUnsafeBufferPointer { p in
        for y in 0..<HH { let fy = (y / SS) * W; let row = y * HW
            for x in 0..<HW { out[fy + x / SS] += Double(p[row + x]) } }
    }
    let k = Double(SS * SS) * 255
    return out.map { $0 / k }
}

// ---------------- digits layout with per-glyph phase "hinting" ----------------
struct Placed { let g: CGGlyph; let x: Double; let baseline: Double }

func layoutRow(_ f: CTFont, _ s: String, top: Double, digitH: Double, centreX: Double) -> [Placed] {
    let gs = s.map { glyph(f, $0) }
    let scale = 1.0 / Double(SS)   // font is at hi-res size; convert to screen px
    let adv = gs.map { Double(advance(f, $0)) * scale }
    let bb = gs.map { bbox(f, $0) }
    let track = -0.02 * digitH
    let baseline = top + digitH
    // ink extents relative to row origin
    let left = Double(bb[0].minX) * scale
    let right = adv[0] + track + Double(bb[1].maxX) * scale
    let x0 = centreX - (left + right) / 2
    var xs = [x0, x0 + adv[0] + track]
    // hint: shift each glyph by up to +-0.5px (in 1/SS steps) to minimise partial-coverage pixels
    for i in 0..<2 {
        var best = xs[i], bestCost = Double.infinity
        for k in -(SS / 2)..<(SS / 2) {
            let x = xs[i] + Double(k) / Double(SS)
            let c = coverage(render([gpath(f, gs[i], x, baseline)]))
            let cost = c.reduce(0) { $0 + $1 * (1 - $1) }
            if cost < bestCost { bestCost = cost; best = x }
        }
        xs[i] = best
    }
    return (0..<2).map { Placed(g: gs[$0], x: xs[$0], baseline: baseline) }
}

// ---------------- shadow sweep ----------------
func sweep(_ m: [UInt8], dx: Double, dy: Double) -> [UInt8] {
    let steps = Int((max(abs(dx), abs(dy)) * Double(SS)).rounded())
    var out = [UInt8](repeating: 0, count: N)
    out.withUnsafeMutableBufferPointer { o in
        m.withUnsafeBufferPointer { s in
            for st in 1...steps {
                let ox = Int((dx * Double(SS) * Double(st) / Double(steps)).rounded())
                let oy = Int((dy * Double(SS) * Double(st) / Double(steps)).rounded())
                for y in max(0, oy)..<min(HH, HH + oy) {
                    let ro = y * HW, rs = (y - oy) * HW
                    for x in max(0, ox)..<min(HW, HW + ox) { let v = s[rs + x - ox]; if v > o[ro + x] { o[ro + x] = v } }
                }
            }
        }
    }
    return out
}

// ---------------- noise ----------------
func hash(_ x: Int, _ y: Int, _ s: Int) -> Double {
    var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ s &* 982451653)
    h = (h ^ (h >> 13)) &* 1274126177; h ^= h >> 16
    return Double(h) / 4294967296.0
}
func vnoise(_ x: Double, _ y: Double, _ s: Int) -> Double {
    let xi = Int(floor(x)), yi = Int(floor(y)); let xf = x - floor(x), yf = y - floor(y)
    let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
    let a = hash(xi, yi, s), b = hash(xi + 1, yi, s), c = hash(xi, yi + 1, s), d = hash(xi + 1, yi + 1, s)
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
}
func fbm(_ x: Double, _ y: Double, _ s: Int, _ o: Int) -> Double {
    var t = 0.0, a = 0.5, f = 1.0
    for i in 0..<o { t += a * vnoise(x * f, y * f, s + i); f *= 2; a *= 0.5 }
    return t
}

// ---------------- moon (first quarter, lit on the right) ----------------
typealias V3 = (Double, Double, Double)
func vec(_ lat: Double, _ lon: Double) -> V3 {
    let a = lat * .pi / 180, o = lon * .pi / 180
    return (cos(a) * sin(o), sin(a), cos(a) * cos(o))
}
func dot(_ a: V3, _ b: V3) -> Double { a.0 * b.0 + a.1 * b.1 + a.2 * b.2 }
func norm(_ a: V3) -> V3 { let l = sqrt(dot(a, a)); return (a.0 / l, a.1 / l, a.2 / l) }

let MCX = 100.0, MCY = 114.0, MR = 92.0
let SUN: V3 = (1, 0, 0)
let MARIA: [(V3, Double, Double)] = [
    (34, -16, 17, 1), (28, 17, 11, 1), (8, 30, 13, 1), (17, 59, 8, 1), (-6, 51, 10, 0.9), (-15, 35, 6, 0.85),
    (-21, -15, 11, 0.75), (-24, -39, 7, 0.9), (13, 4, 5, 0.8), (-10, -23, 6, 0.7), (7, -28, 8, 0.7),
    (15, -55, 16, 0.95), (0, -58, 14, 0.9), (-12, -42, 10, 0.8), (28, -45, 12, 0.9),
    (55, -20, 6, 0.6), (57, 0, 6, 0.6), (56, 20, 6, 0.55),
].map { (vec($0.0, $0.1), $0.2, $0.3) }
// named craters near/right of the first-quarter terminator (lat, lon, radius deg)
var CRATERS: [(V3, Double)] = [
    (-11.4, 26.4, 1.7), (-13.2, 24.0, 1.6), (-18.0, 23.6, 1.7), (31.8, 29.9, 1.4), (-8.9, 61.0, 2.2), (-25.3, 60.4, 2.9),
    (-11.2, 4.3, 2.2), (-5.1, 5.2, 3.0), (-9.3, -1.9, 4.0), (-13.4, -3.2, 3.0), (-18.2, -1.9, 2.6), (-41.8, 14.0, 3.4),
    (-41.0, 6.0, 3.5), (50.2, 17.4, 2.5), (44.3, 16.3, 1.9), (14.5, 9.1, 1.2), (15.4, 23.7, 1.4), (-29.0, 9.0, 2.0),
    (-36.0, 26.0, 2.2), (-48.0, 30.0, 2.4), (-55.0, 12.0, 2.6), (-3.0, 15.0, 1.3), (40.0, 40.0, 1.6),
].map { (vec($0.0, $0.1), $0.2) }
do { // scatter smaller highland craters
    var s: UInt64 = 7
    func r() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / 9007199254740992.0 }
    for _ in 0..<70 { CRATERS.append((vec(-70 + 95 * r(), -5 + 85 * r()), 0.9 + 1.6 * pow(r(), 2))) }
}
let CRCOS = CRATERS.map { cos($0.1 * 2.2 * .pi / 180) }

let K_WHITE = idx(0xFFFFFF), K_LGREY = idx(0xAAAAAA), K_DGREY = idx(0x555555), K_BLACK = 0
let K_UNLIT = idx(0x000055)

var STARS = [Int: Int]()
do {
    var s: UInt64 = 3
    func r() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / 9007199254740992.0 }
    while STARS.count < 26 {
        let x = Int(r() * Double(W - 4)) + 2, y = Int(r() * Double(H - 4)) + 2
        let d = hypot(Double(x) + 0.5 - MCX, Double(y) + 0.5 - MCY)
        if d > MR + 5 && STARS[y * W + x - 1] == nil && STARS[y * W + x + 1] == nil && STARS[(y - 1) * W + x] == nil && STARS[(y + 1) * W + x] == nil {
            STARS[y * W + x] = r() < 0.35 ? idx(0xFFFFFF) : idx(0xAAAAAA)
        }
    }
}

func moonSample(_ hx: Int, _ hy: Int) -> Int {
    let fx = (Double(hx) + 0.5) / Double(SS), fy = (Double(hy) + 0.5) / Double(SS)
    let nx = (fx - MCX) / MR, ny = -(fy - MCY) / MR, r2 = nx * nx + ny * ny
    if r2 >= 1 { return STARS[(hy / SS) * W + hx / SS] ?? K_BLACK }
    let nz = sqrt(1 - r2); let p: V3 = (nx, ny, nz)
    let lat = asin(ny) * 180 / .pi, lon = atan2(nx, nz) * 180 / .pi
    let mu0 = dot(p, SUN)
    // slightly rough terminator: high ground catches light a little past the line
    let rough = (fbm(lon * 0.35 + 50, lat * 0.35, 21, 3) - 0.5) * 0.035
    if mu0 + rough <= 0 { return K_UNLIT }
    // maria: merged soft blobs with noisy edges, then a hard class split
    let n = fbm(lon * 0.07 + 10, lat * 0.07 + 10, 3, 4)
    var keep = 1.0
    for m in MARIA {
        let t = acos(min(1, dot(p, m.0))) * 180 / .pi * (0.7 + 0.6 * n) / m.1
        if t < 2.5 { keep *= 1 - m.2 * exp(-t * t * 1.3) }
    }
    var albedo = (1 - keep) > 0.45 ? 0.62 : 1.0
    // craters: rim-cast shadow on the sun-side floor, bright sun-facing inner wall
    var shade = 0 // 0 normal, 1 shadow, 2 bright wall
    let alt = max(asin(max(-1, min(1, mu0))), 0.02)
    for (i, c) in CRATERS.enumerated() {
        let d0 = dot(p, c.0); if d0 < CRCOS[i] { continue }
        let rr = c.1 * .pi / 180, d = acos(min(1, d0))
        if d > rr { continue }
        let tv = norm((SUN.0 - mu0 * p.0, SUN.1 - mu0 * p.1, SUN.2 - mu0 * p.2))
        let len = min(rr * 1.7, rr * 0.22 / tan(alt))
        let toward = norm((p.0 + len * tv.0, p.1 + len * tv.1, p.2 + len * tv.2))
        let away = norm((p.0 - rr * 0.3 * tv.0, p.1 - rr * 0.3 * tv.1, p.2 - rr * 0.3 * tv.2))
        if acos(min(1, dot(toward, c.0))) > rr { shade = 1 }
        else if acos(min(1, dot(away, c.0))) > rr && shade == 0 { shade = 2 }
        else if shade == 0 { albedo *= 0.9 }
    }
    if shade == 1 { return K_BLACK }
    // Lommel-Seeliger: the real moon stays bright almost to the terminator
    let ls = 2 * mu0 / (mu0 + nz + 1e-6)
    var v = albedo * min(1.0, 4.0 * ls)
    if shade == 2 { v = max(v, 0.8) }
    if v >= 0.70 { return K_WHITE }
    if v >= 0.40 { return K_LGREY }
    if v >= 0.13 { return K_DGREY }
    return K_BLACK
}

// ---------------- compose + palette-aware downsample ----------------
func weightedDist(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
    let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
    return sqrt(2 * dr * dr + 4 * dg * dg + 3 * db * db) / 3
}

struct Layer { let mask: [UInt8]; let colour: (Int, Int) -> Int } // colour(hx, hy) in hi-res coords -> palette idx

func compose(bg: (Int, Int) -> Int, layers: [Layer]) -> [Int] {
    var w = [Double](repeating: 0, count: W * H * 64)
    for hy in 0..<HH {
        let sy = hy / SS
        for hx in 0..<HW {
            let i = hy * HW + hx, pix = sy * W + hx / SS
            var rest = 1.0
            // top-down: last layer is on top
            for li in stride(from: layers.count - 1, through: 0, by: -1) {
                let a = Double(layers[li].mask[i]) / 255
                if a > 0 { w[pix * 64 + layers[li].colour(hx, hy)] += rest * a; rest *= (1 - a); if rest <= 0 { break } }
            }
            if rest > 0 { w[pix * 64 + bg(hx, hy)] += rest }
        }
    }
    let total = Double(SS * SS)
    var out = [Int](repeating: 0, count: W * H)
    for p in 0..<(W * H) {
        var avg = (0.0, 0.0, 0.0)
        for k in 0..<64 where w[p * 64 + k] > 0 { let c = rgb(k), f = w[p * 64 + k] / total; avg.0 += c.0 * f; avg.1 += c.1 * f; avg.2 += c.2 * f }
        var best = 0, bestCost = Double.infinity
        for k in 0..<64 {
            let present = w[p * 64 + k] / total >= 0.03
            let cost = weightedDist(avg, rgb(k)) + (present ? 0 : 20)
            if cost < bestCost { bestCost = cost; best = k }
        }
        out[p] = best
    }
    return out
}

func writePNG(_ px: [Int], _ path: String, scale: Int) {
    let w = W * scale, h = H * scale
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let c = rgb(px[(y / scale) * W + x / scale]), o = (y * w + x) * 4
        bytes[o] = UInt8(c.0); bytes[o + 1] = UInt8(c.1); bytes[o + 2] = UInt8(c.2)
    } }
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
}

// ---------------- scenes ----------------
let args = CommandLine.arguments
let mode = args[1], fontName = args[2], prefix = args[3]

let digitH = Double(ENV["DIGIT_H"] ?? "98")!
// the two rows' cap tops: the block (two rows and a 14 px gap) centred on the screen; PT2 = 9, 121
let ROW_TOP: [Double] = { let t = ((Double(H) - 2 * digitH - 14) / 2).rounded(); return [t, t + digitH + 14] }()
// Photo crops and scattered art were tuned on PT2 (200 x 228 plus whatever margin the mode adds).
// On a bigger screen a crop grows with the texture about its own centre, so a screen pixel covers
// the same source pixels and the detail keeps its size next to the digits. On PT2 both return their
// input unchanged, in every mode. The crop then stays inside the photo (iw x ih): it shrinks if it is
// bigger (the detail grows a little) and slides in if it runs past an edge, so no black padding ever
// reaches the texture.
var REF_TW: Double { Double(200 + TW - W) }
var REF_TH: Double { Double(228 + TH - H) }
func fitCrop(cx: Double, cy: Double, cw: Double, iw: Double, ih: Double) -> (cx: Double, cy: Double, cw: Double, ch: Double) {
    let refH = cw * REF_TH / REF_TW
    var w = cw * (Double(TW) / REF_TW), h = w * Double(TH) / Double(TW)
    var x = cx - (w - cw) / 2, y = cy - (h - refH) / 2
    if w > iw || h > ih { let k = min(iw / w, ih / h); x += w * (1 - k) / 2; y += h * (1 - k) / 2; w *= k; h *= k }
    return (min(max(x, 0), iw - w), min(max(y, 0), ih - h), w, h)
}
func perArea(_ n: Double) -> Int { Int((n * Double(TW * TH) / (REF_TW * REF_TH)).rounded()) }
func digitFont() -> CTFont {
    let probe = makeFont(fontName, 1000)
    let seven = bbox(probe, glyph(probe, "7"))
    let size = digitH / Double(seven.maxY) * 1000 * Double(SS)
    return makeFont(fontName, CGFloat(size))
}

func face(h: String, m: String, shadow: Bool, keyline: Bool, base: Int, topFill: Int, botFill: Int,
          steps: Double, battery: Double, bg: @escaping (Int, Int) -> Int, shadowCol: Int,
          invert: ((Int, Int) -> Bool)? = nil) -> [Int] {
    // part: 0 empty, 1 steps fill, 2 battery fill. When invert(hx,hy) is true the digit sits on a
    // light region and switches to the day palette.
    let dayPal = [K_BLACK, idx(0x00AA00), idx(0x0055FF)]
    let ownPal = [base, topFill, botFill]
    func digitColour(_ hx: Int, _ hy: Int, _ part: Int) -> Int {
        if let inv = invert, inv(hx, hy) { return dayPal[part] }
        return ownPal[part]
    }
    let f = digitFont()
    let cx = shadow ? 106.0 : 100.0
    let top = layoutRow(f, h, top: 9, digitH: digitH, centreX: cx)
    let bot = layoutRow(f, m, top: 121, digitH: digitH, centreX: cx)
    let topM = render(top.map { gpath(f, $0.g, $0.x, $0.baseline) })
    let botM = render(bot.map { gpath(f, $0.g, $0.x, $0.baseline) })
    let fillTopY = Int((9 + digitH - (steps * digitH)).rounded())
    let fillBotY = Int((121 + digitH - (battery * digitH)).rounded())
    var layers: [Layer] = []
    if shadow {
        var both = topM; for i in 0..<N { both[i] = max(both[i], botM[i]) }
        layers.append(Layer(mask: sweep(both, dx: -12, dy: 4), colour: { _, _ in shadowCol }))
    }
    if keyline {
        let kl = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) }, stroke: CGFloat(6 * SS))
        layers.append(Layer(mask: kl, colour: { _, _ in K_BLACK }))
    }
    layers.append(Layer(mask: topM, colour: { hx, hy in digitColour(hx, hy, hy / SS >= fillTopY ? 1 : 0) }))
    layers.append(Layer(mask: botM, colour: { hx, hy in digitColour(hx, hy, hy / SS >= fillBotY ? 2 : 0) }))
    return compose(bg: bg, layers: layers)
}


// ---------------- cutout weather scenes (screen-space, palette-native flat shapes) ----------------
func darken(_ i: Int) -> Int { let r = i / 16, g = i / 4 % 4, b = i % 4; return max(r - 1, 0) * 16 + max(g - 1, 0) * 4 + max(b - 1, 0) }
func inCloud(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ s: Double) -> (Bool, Bool) {
    // union of puffs with a flat base; second value = lower "underside" band
    if y > cy + 10 * s { return (false, false) }
    let puffs: [(Double, Double, Double)] = [(-26, 2, 13), (-10, -8, 17), (10, -12, 19), (28, -2, 14), (0, 2, 14)]
    for p in puffs { if hypot(x - (cx + p.0 * s), y - (cy + p.1 * s)) < p.2 * s { return (true, y > cy + 2 * s) } }
    return (false, false)
}
func sceneSun(_ hx: Int, _ hy: Int) -> Int {
    let x = (Double(hx) + 0.5) / Double(SS), y = (Double(hy) + 0.5) / Double(SS)
    let sx = 150.0, sy = 58.0, d = hypot(x - sx, y - sy)
    if d < 24 { return idx(0xFFFF55) }
    if d < 31 { return idx(0xFFFFAA) }
    let a = atan2(y - sy, x - sx) + .pi
    return Int(floor(a / (2 * .pi / 20))) % 2 == 0 ? idx(0xAAFFFF) : idx(0x55AAFF)
}
func sceneCloud(_ hx: Int, _ hy: Int) -> Int {
    let x = (Double(hx) + 0.5) / Double(SS), y = (Double(hy) + 0.5) / Double(SS)
    for c in [(58.0, 62.0, 1.35), (150.0, 150.0, 1.5), (40.0, 196.0, 1.1), (170.0, 40.0, 0.9)] {
        let r = inCloud(x, y, c.0, c.1, c.2); if r.0 { return r.1 ? idx(0xAAAAAA) : idx(0xFFFFFF) }
    }
    if hypot(x - 178, y - 22) < 20 { return idx(0xFFFF55) }
    return idx(0x55AAFF)
}
func sceneRain(_ hx: Int, _ hy: Int) -> Int {
    let x = (Double(hx) + 0.5) / Double(SS), y = (Double(hy) + 0.5) / Double(SS)
    let s = x + y / 3, lane = floor(s / 9)
    let across = s / 9 - lane, along = (y + 41 * lane).truncatingRemainder(dividingBy: 26) / 26
    if across < 0.17 && along < 0.45 { return idx(0x0055AA) }
    return idx(0xAAAAAA)
}
func cutout(h: String, m: String, scene: @escaping (Int, Int) -> Int, plate: Int) -> [Int] {
    let f = digitFont()
    let top = layoutRow(f, h, top: 9, digitH: digitH, centreX: 100)
    let bot = layoutRow(f, m, top: 121, digitH: digitH, centreX: 100)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    let plateMask = win.map { 255 - $0 }
    let inner = sweep(plateMask, dx: -6, dy: 2)   // the plate edge's own sundial shadow, cast into each window
    let layer = Layer(mask: win, colour: { hx, hy in let c = scene(hx, hy); return inner[hy * HW + hx] >= 128 ? darken(c) : c })
    return compose(bg: { _, _ in plate }, layers: [layer])
}
func moonLit(_ hx: Int, _ hy: Int) -> Bool {
    let fx = (Double(hx) + 0.5) / Double(SS), fy = (Double(hy) + 0.5) / Double(SS)
    let nx = (fx - MCX) / MR, ny = -(fy - MCY) / MR
    return nx * nx + ny * ny < 1 && nx > 0.07   // the dark band at the terminator counts as night
}

// ---------------- stylized night: exact inverse-pair palette ----------------
func invert(_ i: Int) -> Int { (3 - i / 16) * 16 + (3 - i / 4 % 4) * 4 + (3 - i % 4) }
let N_SKY = idx(0x000055), N_MOON = idx(0xFFFFAA), N_CRATER = idx(0xAAAA55)
let SCRATERS: [(Double, Double, Double)] = [(128, 78, 13), (150, 128, 9), (118, 150, 16), (165, 90, 6), (135, 185, 8), (172, 160, 5),
                                            (62, 95, 11), (78, 150, 8), (45, 130, 6), (70, 60, 7)]
let SSTARS: [(Double, Double, Double)] = [(18, 22, 5), (182, 16, 4), (190, 206, 5), (12, 180, 4), (30, 212, 3), (178, 60, 3)]
var PHASE_E = Double.pi / 2, PHASE_WAX = true
func moonStyl(_ hx: Int, _ hy: Int) -> Int {
    let x = (Double(hx) + 0.5) / Double(SS), y = (Double(hy) + 0.5) / Double(SS)
    let nx = (x - MCX) / MR, ny = -(y - MCY) / MR, r2 = nx * nx + ny * ny
    if r2 >= 1 {
        for st in SSTARS {   // four-point sparkle, concave sides
            let dx = abs(x - st.0), dy = abs(y - st.1)
            if sqrt(dx) + sqrt(dy) < sqrt(st.2) { return N_MOON }
        }
        return N_SKY
    }
    let nz = sqrt(1 - r2), sx = PHASE_WAX ? sin(PHASE_E) : -sin(PHASE_E)
    if nx * sx - nz * cos(PHASE_E) <= 0 { return N_SKY }   // unlit side vanishes into the sky
    let sunX = PHASE_WAX ? 1.0 : -1.0
    for c in SCRATERS {
        if hypot(x - c.0, y - c.1) < c.2 {
            // rim shadow: the crescent on the sun side, same idea as the day face's hard shadow
            return hypot(x - (c.0 - sunX * c.2 * 0.38), y - c.1) < c.2 ? N_MOON : N_CRATER
        }
    }
    return N_MOON
}
func nightStyl(h: String, m: String) -> [Int] {
    let f = digitFont()
    let top = layoutRow(f, h, top: 9, digitH: digitH, centreX: 100)
    let bot = layoutRow(f, m, top: 121, digitH: digitH, centreX: 100)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    return compose(bg: moonStyl, layers: [Layer(mask: win, colour: { hx, hy in invert(moonStyl(hx, hy)) })])
}

// ---------------- day weather windows: repeating patterns so any digits read the same ----------------
func inPoly(_ x: Double, _ y: Double, _ p: [(Double, Double)]) -> Bool {
    var c = false; var j = p.count - 1
    for i in 0..<p.count {
        if (p[i].1 > y) != (p[j].1 > y) && x < (p[j].0 - p[i].0) * (y - p[i].1) / (p[j].1 - p[i].1) + p[i].0 { c.toggle() }
        j = i
    }
    return c
}
// staggered tile: returns offset of (x,y) from the nearest motif centre
func tile(_ x: Double, _ y: Double, _ sx: Double, _ sy: Double) -> (Double, Double) {
    let row = floor(y / sy), ox = row.truncatingRemainder(dividingBy: 2) == 0 ? 0 : sx / 2
    let cx = floor((x - ox) / sx) * sx + ox + sx / 2, cy = row * sy + sy / 2
    return (x - cx, y - cy)
}
func sceneSunny(_ hx: Int, _ hy: Int) -> Int {
    let x = (Double(hx) + 0.5) / Double(SS), y = (Double(hy) + 0.5) / Double(SS)
    let (dx, dy) = tile(x, y, 30, 26)
    let r = hypot(dx, dy), a = atan2(dy, dx) + .pi / 8
    let k = a / (2 * .pi / 8), tri = 1 - abs(k - floor(k) - 0.5) * 2    // 1 at a ray tip, 0 between
    if r < 6 { return idx(0xFFFF00) }
    if r < 6 + 6 * pow(tri, 3) { return idx(0xFFAA00) }
    return idx(0x0055FF)
}
func sceneDrops(_ hx: Int, _ hy: Int) -> Int {
    let x = (Double(hx) + 0.5) / Double(SS), y = (Double(hy) + 0.5) / Double(SS)
    let (dx, dy0) = tile(x, y, 26, 28), dy = dy0 - 3
    let R = 6.5, tip = -15.0
    var inside = hypot(dx, dy) < R
    if !inside && dy < 0 && dy > tip { let t = (dy - tip) / (0 - tip); inside = abs(dx) < R * pow(t, 1.6) }
    if inside { return hypot(dx + 2.3, dy + 0.5) < 1.9 ? idx(0xFFFFFF) : idx(0x55AAFF) }
    return idx(0x555555)
}
let BOLT: [(Double, Double)] = [(3, -13), (-6, 1), (-1, 1), (-4, 13), (7, -3), (2, -3), (5, -13)]
func sceneStorm(_ hx: Int, _ hy: Int) -> Int {
    let x = (Double(hx) + 0.5) / Double(SS), y = (Double(hy) + 0.5) / Double(SS)
    let (dx, dy) = tile(x, y, 26, 30)
    return inPoly(dx, dy, BOLT) ? idx(0xFFFF00) : idx(0x000055)
}
func erode(_ m: [UInt8], _ r: Int) -> [UInt8] {
    var a = [UInt8](repeating: 0, count: N), b = [UInt8](repeating: 0, count: N)
    m.withUnsafeBufferPointer { s in a.withUnsafeMutableBufferPointer { o in
        for y in 0..<HH { let row = y * HW
            for x in 0..<HW { var mn: UInt8 = 255; for k in max(0, x - r)...min(HW - 1, x + r) { let v = s[row + k]; if v < mn { mn = v; if mn == 0 { break } } }; o[row + x] = (x < r || x >= HW - r) ? 0 : mn } } } }
    a.withUnsafeBufferPointer { s in b.withUnsafeMutableBufferPointer { o in
        for y in 0..<HH { for x in 0..<HW { var mn: UInt8 = 255
            for k in max(0, y - r)...min(HH - 1, y + r) { let v = s[k * HW + x]; if v < mn { mn = v; if mn == 0 { break } } }
            o[y * HW + x] = (y < r || y >= HH - r) ? 0 : mn } } } }
    return b
}
var SKY_OF: [String: Int] = [:]
// low-res distance (px) from each window pixel to the plate, capped
func insideDistance(_ win: [UInt8]) -> [Double] {
    let c = coverage(win), cap = 8
    var d = [Double](repeating: 0, count: W * H)
    for y in 0..<H { for x in 0..<W where c[y * W + x] >= 0.5 {
        var best = Double(cap)
        for j in -cap...cap { for i in -cap...cap {
            let X = x + i, Y = y + j
            if X < 0 || Y < 0 || X >= W || Y >= H || c[Y * W + X] < 0.5 { best = min(best, hypot(Double(i), Double(j))) } } }
        d[y * W + x] = best } }
    return d
}
func dayWindow(h: String, m: String, scene: @escaping (Int, Int) -> Int, sky: Int, tileW: Double, tileH: Double) -> [Int] {
    let f = digitFont()
    let top = layoutRow(f, h, top: 9, digitH: digitH, centreX: 106)
    let bot = layoutRow(f, m, top: 121, digitH: digitH, centreX: 106)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    let plate = idx(0xFFFFAA), shade = idx(0xAAAA55)
    let inner = erode(win, 2 * SS)   // motifs stay 2px clear of every digit edge
    let dist = insideDistance(win)
    // a motif whose centre falls outside (or right at the edge of) the window is dropped whole,
    // so no stray slivers; motifs centred inside may still be cut by the edge clearance
    func motifOK(_ hx: Int, _ hy: Int) -> Bool {
        let x = (Double(hx) + 0.5) / Double(SS), y = (Double(hy) + 0.5) / Double(SS)
        let t = tile(x, y, tileW, tileH); let cx = Int(x - t.0), cy = Int(y - t.1)
        return cx >= 0 && cy >= 0 && cx < W && cy < H && dist[cy * W + cx] >= 3
    }
    return compose(bg: { _, _ in plate }, layers: [Layer(mask: sweep(win, dx: -12, dy: 4), colour: { _, _ in shade }),
                                                   Layer(mask: win, colour: { hx, hy in inner[hy * HW + hx] >= 128 && motifOK(hx, hy) ? scene(hx, hy) : sky })])
}

// ---------------- photo pipeline: load, crop, tone, dither onto a luminance ramp ----------------
func loadImage(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
// crop (source px, y-down) scaled to W x H, returns luminance 0..1 (Rec.601 on sRGB values)
func sampleCrop(_ img: CGImage, cx: Double, cy: Double, cw: Double, ch: Double) -> [Double] {
    var bytes = [UInt8](repeating: 0, count: TW * TH * 4)
    let ctx = CGContext(data: &bytes, width: TW, height: TH, bitsPerComponent: 8, bytesPerRow: TW * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: TW, height: TH))
    ctx.interpolationQuality = .high
    let s = Double(TW) / cw, iw = Double(img.width), ih = Double(img.height)
    ctx.draw(img, in: CGRect(x: -cx * s, y: -(ih - (cy + ch)) * s, width: iw * s, height: ih * s))
    var out = [Double](repeating: 0, count: TW * TH)
    for i in 0..<(TW * TH) { out[i] = (0.299 * Double(bytes[i * 4]) + 0.587 * Double(bytes[i * 4 + 1]) + 0.114 * Double(bytes[i * 4 + 2])) / 255 }
    return out
}
func boxBlur(_ a: [Double], _ r: Int) -> [Double] {
    var b = a, t = a
    for _ in 0..<3 {
        for y in 0..<TH { for x in 0..<TW { var s = 0.0, n = 0.0; for k in max(0, x - r)...min(TW - 1, x + r) { s += b[y * TW + k]; n += 1 }; t[y * TW + x] = s / n } }
        for y in 0..<TH { for x in 0..<TW { var s = 0.0, n = 0.0; for k in max(0, y - r)...min(TH - 1, y + r) { s += t[k * TW + x]; n += 1 }; b[y * TW + x] = s / n } }
    }
    return b
}
func lumOf(_ i: Int) -> Double { let c = rgb(i); return (0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2) / 255 }
// ramp: palette colours ordered dark to light; map t in 0..1 onto the ramp's own luminance span
func ditherRamp(_ l: [Double], _ ramp: [Int], method: String, strength: Double) -> [Int] {
    let lv = ramp.map(lumOf), lo = lv.first!, hi = lv.last!
    var e = l.map { lo + $0 * (hi - lo) }
    var out = [Int](repeating: ramp[0], count: TW * TH)
    func pick(_ v: Double) -> Int { var b = 0; for k in 1..<ramp.count where abs(lv[k] - v) < abs(lv[b] - v) { b = k }; return b }
    func add(_ x: Int, _ y: Int, _ v: Double) { if x >= 0 && x < TW && y < TH { e[y * TW + x] += v } }
    if method == "bayer" {
        let M = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
        for y in 0..<TH { for x in 0..<TW {
            let v = e[y * TW + x]; var k = 0; while k + 1 < lv.count && lv[k + 1] <= v { k += 1 }
            if k + 1 >= lv.count { out[y * TW + x] = ramp[k]; continue }
            let f = (v - lv[k]) / (lv[k + 1] - lv[k]), th = 0.5 + ((Double(M[y & 3][x & 3]) + 0.5) / 16 - 0.5) * strength
            out[y * TW + x] = ramp[f > th ? k + 1 : k] } }
        return out
    }
    for y in 0..<TH {
        let rev = method == "fs" && y % 2 == 1
        for xx in 0..<TW {
            let x = rev ? TW - 1 - xx : xx, v = e[y * TW + x], k = pick(v)
            out[y * TW + x] = ramp[k]
            if method == "none" { continue }
            let err = (v - lv[k]) * strength, d = rev ? -1 : 1
            if method == "atkinson" {
                let q = err / 8
                add(x + 1, y, q); add(x + 2, y, q); add(x - 1, y + 1, q); add(x, y + 1, q); add(x + 1, y + 1, q); add(x, y + 2, q)
            } else {
                add(x + d, y, err * 7 / 16); add(x - d, y + 1, err * 3 / 16); add(x, y + 1, err * 5 / 16); add(x + d, y + 1, err / 16)
            }
        }
    }
    return out
}
func moonTone(at: (Double, Double)? = nil, diameter: Double? = nil) -> [Double] {
    let img = loadImage(ENV["MOONFILE"] ?? "src/moon.jpg")
    // find the disc: bounding box of pixels brighter than the sky
    var bytes = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let c = CGContext(data: &bytes, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    var x0 = img.width, x1 = 0, y0 = img.height, y1 = 0
    for y in 0..<img.height { for x in 0..<img.width where bytes[(y * img.width + x) * 4 + 1] > 22 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
    let d = Double(max(x1 - x0, y1 - y0) + 1), s = (diameter ?? Double(ENV["MD"] ?? "184")!) / d
    let mcx = Double(x0 + x1 + 1) / 2, mcy = Double(y0 + y1 + 1) / 2
    let cw = Double(TW) / s, ch = Double(TH) / s
    let px0 = at?.0 ?? Double(ENV["MX"] ?? "100")! + Double(ENVMX), py0 = at?.1 ?? Double(ENV["MY"] ?? "114")! + Double(ENVMX)
    var l = sampleCrop(img, cx: mcx - px0 / s, cy: mcy - py0 / s, cw: cw, ch: ch)
    let bl = boxBlur(l, 1)
    for i in 0..<l.count {
        var v = l[i] + 0.7 * (l[i] - bl[i])                // unsharp: keep crater detail at 184px
        v = (v - MOON_BLACK) / (MOON_WHITE - MOON_BLACK)   // crush the dim unlit half to black
        l[i] = pow(max(0, min(1, v)), MOON_GAMMA)
    }
    return l
}
var MOON_BLACK = Double(ENV["MB"] ?? "0.2")!, MOON_WHITE = Double(ENV["MW"] ?? "0.9")!, MOON_GAMMA = Double(ENV["MG"] ?? "1.0")!
func dropsTone(_ path: String, fx: Double, fy: Double, fw: Double) -> [Double] {
    let img = loadImage(path)
    let iw = Double(img.width), ih = Double(img.height)
    let c = fitCrop(cx: iw * fx, cy: ih * fy, cw: iw * fw, iw: iw, ih: ih)
    var l = sampleCrop(img, cx: c.cx, cy: c.cy, cw: c.cw, ch: c.ch)
    // flatten the big light-to-dark gradient so every cutout sees the same texture
    let bg = boxBlur(l, 18)
    var mn = 1.0, mx = 0.0
    for i in 0..<l.count { l[i] = l[i] - bg[i]; mn = min(mn, l[i]); mx = max(mx, l[i]) }
    let bl = boxBlur(l, 1)
    for i in 0..<l.count { l[i] = l[i] + 0.5 * (l[i] - bl[i]) }
    // robust stretch: 2nd to 98th percentile
    let sorted = l.sorted(), p2 = sorted[l.count / 50], p98 = sorted[l.count * 49 / 50]
    let t = l.map { max(0, min(1, ($0 - p2) / (p98 - p2))) }
    // land the typical glass tone exactly on the ramp's middle level, with a dead zone, so the
    // flat glass is one solid palette colour and only the droplets carry dither
    let med = t.sorted()[t.count / 2], dz = Double(ENV["DZ"] ?? "0.08")!, mid = Double(ENV["MID"] ?? "0.5")!
    return t.map { v in
        if abs(v - med) < dz { return mid }
        return v < med ? (v / (med - dz)) * mid * (v < med - dz ? 1 : 0) + (v >= med - dz ? mid : 0)
                       : mid + (v - med - dz) / (1 - med - dz) * (1 - mid)
    }
}
func photoFace(bgIdx: [Int], h: String, m: String, digit: Int, shadow: Bool, window: Bool, plate: Int = 0, shade: Int = 0) -> [Int] {
    let f = digitFont()
    let cx = shadow ? 106.0 : 100.0
    let top = layoutRow(f, h, top: 9, digitH: digitH, centreX: cx)
    let bot = layoutRow(f, m, top: 121, digitH: digitH, centreX: cx)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    let photo: (Int, Int) -> Int = { hx, hy in bgIdx[(hy / SS) * W + hx / SS] }
    if window {
        var layers = [Layer]()
        if shadow { layers.append(Layer(mask: sweep(win, dx: -12, dy: 4), colour: { _, _ in shade })) }
        layers.append(Layer(mask: win, colour: photo))
        return compose(bg: { _, _ in plate }, layers: layers)
    }
    return compose(bg: photo, layers: [Layer(mask: win, colour: { _, _ in digit })])
}
let GREY4 = [0x000000, 0x555555, 0xAAAAAA, 0xFFFFFF].map(idx)

// plain photo tone: crop, optional flatten, sharpen, percentile stretch, gamma (no dead-zone snap)
func plainTone(_ path: String, fx: Double, fy: Double, fw: Double, flatten: Int, sharpen: Double, gamma: Double) -> [Double] {
    let img = loadImage(path)
    let iw = Double(img.width), ih = Double(img.height)
    let c = fitCrop(cx: iw * fx, cy: ih * fy, cw: iw * fw, iw: iw, ih: ih)
    var l = sampleCrop(img, cx: c.cx, cy: c.cy, cw: c.cw, ch: c.ch)
    if flatten > 0 { let bg = boxBlur(l, flatten); for i in 0..<l.count { l[i] = l[i] - bg[i] } }
    let bl = boxBlur(l, 1)
    for i in 0..<l.count { l[i] = l[i] + sharpen * (l[i] - bl[i]) }
    let sorted = l.sorted(), p2 = sorted[l.count / 50], p98 = sorted[l.count * 49 / 50]
    return l.map { pow(max(0, min(1, ($0 - p2) / (p98 - p2))), gamma) }
}
func cloudsT() -> [Double] { plainTone("src/clouds.jpg", fx: 0.2, fy: 0.0, fw: 0.58, flatten: 0, sharpen: 0.4, gamma: 1.3) }
func frostT() -> [Double] { plainTone("src/frost.jpg", fx: 0.3, fy: 0.05, fw: 0.5, flatten: 30, sharpen: 0.6, gamma: 1.0) }
func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }

// small text line (for the backlight detail view), returned as a hi-res mask
func textMask(_ str: String, size: Double, centreX: Double, baseline: Double) -> [UInt8] {
    let f = makeFont("SF-Bold", CGFloat(size * Double(SS)))
    let attr = NSAttributedString(string: str, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f,
                                                          NSAttributedString.Key(kCTKernAttributeName as String): 0.6 * Double(SS),
                                                          NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
    let line = CTLineCreateWithAttributedString(attr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    let ctx = CGContext(data: nil, width: HW, height: HH, bitsPerComponent: 8, bytesPerRow: HW,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: HW, height: HH))
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.textPosition = CGPoint(x: centreX * Double(SS) - w / 2, y: Double(HH) - baseline * Double(SS))
    // CTLineDraw uses the context fill colour when the string has no colour attribute
    CTLineDraw(line, ctx)
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: N)
    return Array(UnsafeBufferPointer(start: p, count: N))
}

// ---------------- animation previews (GIF) ----------------
func writeGIF(_ frames: [[Int]], _ path: String, scale: Int, delay: Double) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "com.compuserve.gif" as CFString, frames.count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
    let w = W * scale, h = H * scale
    for px in frames {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = rgb(px[(y / scale) * W + x / scale]), o = (y * w + x) * 4
            bytes[o] = UInt8(c.0); bytes[o + 1] = UInt8(c.1); bytes[o + 2] = UInt8(c.2) } }
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
}
// simulated wrist tilt over one loop: a slow figure-eight, in whole pixels
func tilt(_ f: Int, _ n: Int, _ ax: Double, _ ay: Double) -> (Int, Int) {
    let t = 2 * Double.pi * Double(f) / Double(n)
    return (Int((ax * sin(t)).rounded()), Int((ay * sin(2 * t)).rounded()))
}
let FLAKES: [[String]] = [
    [".#.", "###", ".#."],
    ["..#..", "#.#.#", ".###.", "#.#.#", "..#.."],
    ["...#...", ".#.#.#.", "..###..", "#######", "..###..", ".#.#.#.", "...#..."],
]
struct Flake { let x0: Double; let y0: Double; let depth: Int; let laps: Int; let phase: Double }
func makeFlakes(_ n: Int, seed: UInt64) -> [Flake] {
    var s = seed
    func r() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / 9007199254740992.0 }
    return (0..<n).map { i in let d = i % 3; return Flake(x0: r() * Double(W + 40) - 20, y0: r() * Double(H + 20), depth: d, laps: d + 1, phase: r() * 6.28) }
}
// draw flakes into a 1x palette-index frame; far flakes grey, near flakes white
func drawFlakes(_ fr: inout [Int], _ flakes: [Flake], _ f: Int, _ n: Int, _ tx: Int, _ ty: Int, colours: [Int]) {
    for k in flakes {
        let spr = FLAKES[k.depth], sz = spr.count, par = [0.35, 0.7, 1.1][k.depth]
        let t = Double(f) / Double(n)
        let y = Int((k.y0 + t * Double(k.laps) * Double(H + 20)).truncatingRemainder(dividingBy: Double(H + 20))) - 10 + Int((Double(ty) * par).rounded())
        let x = Int((k.x0 + 3 * sin(2 * .pi * t * Double(k.laps) + k.phase)).rounded()) + Int((Double(tx) * par).rounded())
        for (j, row) in spr.enumerated() { for (i, ch) in row.enumerated() where ch == "#" {
            let X = x + i - sz / 2, Y = y + j - sz / 2
            if X >= 0 && Y >= 0 && X < W && Y < H { fr[Y * W + X] = colours[k.depth] } } }
    }
}

// shift a hi-res mask by (dx,dy) hi-res px (outside = 0)
func shifted(_ m: [UInt8], _ dx: Int, _ dy: Int) -> [UInt8] {
    var o = [UInt8](repeating: 0, count: N)
    for y in max(0, dy)..<min(HH, HH + dy) { let ro = y * HW, rs = (y - dy) * HW
        for x in max(0, dx)..<min(HW, HW + dx) { o[ro + x] = m[rs + x - dx] } }
    return o
}
// one frame of "digits cut through a plate, texture lying a little below it":
//  floor point seen through p is q = p + o (parallax); if q is not under the hole, you're looking at the hole's wall;
//  the plate's own silhouette, displaced along the sunlight, is the shadow on the floor.
func carvedFrame(win: [UInt8], plateShadowFloor: [UInt8], tex: [Int], texW: Int, margin: Int, ox: Int, oy: Int,
                 plate: Int, wall: Int, frame: [UInt8]? = nil, frameCol: Int = 0, darkenShadow: @escaping (Int) -> Int = darken) -> [Int] {
    let underHole = shifted(win, -ox * SS, -oy * SS)  // win[p + o]
    var layers: [Layer] = []
    if let fr = frame { layers.append(Layer(mask: fr, colour: { _, _ in frameCol })) }
    layers.append(Layer(mask: win, colour: { hx, hy in
        let i = hy * HW + hx
        if underHole[i] < 128 { return wall }
        let qx = hx / SS + ox, qy = hy / SS + oy
        let t = tex[(qy + margin) * texW + qx + margin]
        let fx = hx + ox * SS, fy = hy + oy * SS
        if fx >= 0 && fy >= 0 && fx < HW && fy < HH && plateShadowFloor[fy * HW + fx] >= 128 { return darkenShadow(t) }
        return t
    }))
    return compose(bg: { _, _ in plate }, layers: layers)
}

// ---------------- the seven weather textures (canvas TW x TH, values 0..1) ----------------
func lcg(_ seed: UInt64) -> () -> Double {
    var s = seed
    return { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / 9007199254740992.0 }
}
func stampMax(_ l: inout [Double], _ cx: Double, _ cy: Double, _ rad: Double, _ f: (Double, Double) -> Double) {
    let r = Int(rad.rounded(.up)) + 1
    let y0 = max(0, Int(cy) - r), y1 = min(TH - 1, Int(cy) + r), x0 = max(0, Int(cx) - r), x1 = min(TW - 1, Int(cx) + r)
    if y0 > y1 || x0 > x1 { return }
    for y in y0...y1 { for x in x0...x1 {
        let v = f(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy); if v > l[y * TW + x] { l[y * TW + x] = v } } }
}
func genSunny() -> [Double] {   // sun glitter on water: dark rippled water, thin wave highlights, star-shaped glints
    var l = [Double](repeating: 0, count: TW * TH)
    for y in 0..<TH { for x in 0..<TW {
        let X = Double(x), Y = Double(y)
        var v = 0.238 /* exactly #0055AA: flat water */
        v += 0.42 * pow(max(0, sin(Y * 0.55 + 5 * fbm(X * 0.02, Y * 0.05, 72, 3) + X * 0.03)), 16)
        l[y * TW + x] = v } }
    let r = lcg(21)
    for cy in stride(from: 0, to: TH, by: 11) { for cx in stride(from: 0, to: TW, by: 12) where r() < 0.6 {
        let px = Double(cx) + r() * 12, py = Double(cy) + r() * 11, sz = 1.6 + 2.6 * pow(r(), 1.5)
        stampMax(&l, px, py, sz * 2.6) { dx, dy in
            let arm = max(0, 1 - min(abs(dx), abs(dy)) / 0.6) * max(0, 1 - max(abs(dx), abs(dy)) / (sz * 2.6))
            let core = exp(-(dx * dx + dy * dy) / (sz * 0.6))
            return max(core, arm * 0.9)
        }
    } }
    return l
}
func genSnow() -> [Double] {    // flash-lit falling snow: far dim specks, mid crisp flakes, near soft discs
    var l = [Double](repeating: 0, count: TW * TH)
    for y in 0..<TH { for x in 0..<TW { l[y * TW + x] = 0.1 + 0.08 * (fbm(Double(x) * 0.02, Double(y) * 0.02, 81, 3) - 0.5) } }
    let r = lcg(33), area = Double(TW * TH)
    for (count, rmin, rmax, bright, soft) in [(area / 110, 0.6, 1.0, 0.45, false), (area / 260, 1.3, 2.2, 0.95, false), (area / 1300, 2.8, 4.2, 0.75, true)] {
        for _ in 0..<Int(count) {
            let px = r() * Double(TW), py = r() * Double(TH), rad = rmin + (rmax - rmin) * r()
            stampMax(&l, px, py, rad + 1) { dx, dy in
                let d = hypot(dx, dy * 0.85)
                var a = max(0, min(1, rad + 0.5 - d))
                if soft { a *= 0.65 + 0.35 * max(0, min(1, d - (rad - 1.3))) }   // bokeh disc with a brighter rim
                return 0.1 + (bright - 0.1) * a
            }
        }
    }
    return l
}
func genFog() -> [Double] {     // condensation: dense small beads on misted glass
    var l = [Double](repeating: 0, count: TW * TH)
    for y in 0..<TH { for x in 0..<TW { l[y * TW + x] = 0.5 /* exactly #55AAAA: flat mist */ } }
    let r = lcg(44)
    for _ in 0..<(TW * TH / 70) {
        let px = r() * Double(TW), py = r() * Double(TH), rad = 2.0 + 2.8 * pow(r(), 1.6)
        let y0 = max(0, Int(py - rad) - 1), y1 = min(TH - 1, Int(py + rad) + 1), x0 = max(0, Int(px - rad) - 1), x1 = min(TW - 1, Int(px + rad) + 1)
        for y in y0...y1 { for x in x0...x1 {
            let dx = Double(x) + 0.5 - px, dy = Double(y) + 0.5 - py, d = hypot(dx, dy)
            if d > rad + 0.5 { continue }
            var v = 0.5                                                         // bead body: same as the mist
            if dx + dy > rad * 0.45 { v = 0.0 }                                // shaded lower-right rim
            if hypot(dx + rad * 0.35, dy + rad * 0.35) < max(0.7, rad * 0.35) { v = 1.0 }   // highlight
            l[y * TW + x] = v } }
    }
    return l
}
let WX: [String: (tex: () -> [Double], ramp: [Int])] = [
    "sunny":  ({ genSunny() }, [0x000055, 0x0055AA, 0x55AAFF, 0xFFFFFF]),
    "partly": ({ plainTone("src/mackerel.jpg", fx: 0.2, fy: 0.2, fw: 0.5, flatten: 28, sharpen: 0.5, gamma: 1.1) }, [0x000055, 0x0055AA, 0x55AAFF]),
    "cloudy": ({ plainTone("src/mackerel.jpg", fx: 0.2, fy: 0.2, fw: 0.5, flatten: 28, sharpen: 0.5, gamma: 0.9) }, [0x000055, 0x5555AA, 0xAAAAAA]),
    "rain":   ({ dropsTone("src/drops_grey.jpg", fx: 0.15, fy: 0.0, fw: 0.58) }, [0x000000, 0x555555, 0xAAAAAA]),
    "snow":   ({ genSnow() }, [0x000055, 0x5555AA, 0xFFFFFF]),
    "storm":  ({ plainTone("src/lightning.jpg", fx: 0.12, fy: 0.1, fw: 0.45, flatten: 0, sharpen: 0.3, gamma: 1.8) }, [0x000000, 0x000055, 0x5555FF, 0xFFFFFF]),
    "fog":    ({ genFog() }, [0x005555, 0x55AAAA, 0xAAFFFF]),
]
func stepUp(_ i: Int) -> Int { min(i / 16 + 1, 3) * 16 + min(i / 4 % 4 + 1, 3) * 4 + min(i % 4 + 1, 3) }
// brighten one step without shifting hue: greys brighten evenly; colours raise their strongest channel, or once it is maxed, the others
func stepUpHue(_ i: Int) -> Int {
    var c = [i / 16, i / 4 % 4, i % 4]
    let mx = c.max()!
    if c[0] == c[1] && c[1] == c[2] { c = c.map { min($0 + 1, 3) } }
    else if mx < 3 { c = c.map { $0 == mx ? $0 + 1 : $0 } }
    else { c = c.map { $0 == 3 ? 3 : min($0 + 1, 3) } }
    return c[0] * 16 + c[1] * 4 + c[2]
}
let NO_LIT_STEP: Set<String> = []

// ---------------- revised weather set: textures produced directly as palette indices ----------------
func pickLevels(_ t: [Double], _ ramp: [Int]) -> [Int] { ditherRamp(t, ramp, method: "none", strength: 0) }
func mergeBy(_ mask: [Bool], _ a: [Int], _ b: [Int]) -> [Int] { (0..<a.count).map { mask[$0] ? a[$0] : b[$0] } }
// big sun centred on the screen (canvas centre), limb-darkened disc with granulation, glow into a blue sky
func sunLayers(radius R: Double) -> (sky: [Int], disc: [Int], inDisc: [Bool]) {
    let cx = Double(TW) / 2, cy = Double(TH) / 2
    var ts = [Double](repeating: 0, count: TW * TH), td = ts, inside = [Bool](repeating: false, count: TW * TH)
    let spots: [(Double, Double, Double)] = [(-0.35, 0.2, 0.07), (-0.28, 0.27, 0.04), (0.3, -0.25, 0.05)]
    for y in 0..<TH { for x in 0..<TW {
        let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy, d = hypot(dx, dy), i = y * TW + x
        if d < R {
            inside[i] = true
            let mu = sqrt(1 - (d / R) * (d / R))
            var v = 0.35 + 0.65 * pow(mu, 0.6)                                    // limb darkening
            v += 0.10 * (fbm(Double(x) * 0.35, Double(y) * 0.35, 17, 3) - 0.5)   // granulation
            for sp in spots where hypot(dx / R - sp.0, dy / R - sp.1) < sp.2 { v -= 0.45 }
            td[i] = max(0, min(1, v))
        } else {
            ts[i] = max(0, min(1, 0.95 * exp(-(d - R) / 22)))                    // glow fading into the sky
        }
    } }
    let sky = ditherRamp(ts, [0x0055AA, 0x55AAFF].map(idx), method: "atkinson", strength: 1)
    // core capped at orange: a pale-yellow core would melt digit edges into the #FFFFAA plate
    let disc = ditherRamp(td, [0xAA5500, 0xFF5500, 0xFFAA00].map(idx), method: "atkinson", strength: 1)
    return (sky, disc, inside)
}
func texSunny() -> [Int] { let s = sunLayers(radius: 60); return mergeBy(s.inDisc, s.disc, s.sky) }
func mackerel() -> [Double] { plainTone("src/mackerel.jpg", fx: 0.2, fy: 0.2, fw: 0.5, flatten: 28, sharpen: 0.5, gamma: 1.0) }
func texPartly() -> [Int] {
    let s = sunLayers(radius: 50)
    let base = mergeBy(s.inDisc, s.disc, s.sky), c = mackerel()
    // crisp two-tone clouds covering ~45%: shaded underside + lit body, no dither
    return (0..<base.count).map { i in c[i] > 0.72 ? idx(0xAAAAAA) : (c[i] > 0.64 ? idx(0x5555AA) : base[i]) }
}
func texCloudy() -> [Int] {
    let c = mackerel()
    let med = c.sorted()[c.count / 2]
    let t = c.map { v -> Double in abs(v - med) < 0.08 ? 0.5 : (v < med ? 0.5 * v / med : 0.5 + 0.5 * (v - med) / (1 - med)) }
    return ditherRamp(t, [0x000055, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 0.7)
}
func texSnowflakes() -> [Int] {
    let w = TW * SS, h = TH * SS
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setLineCap(.round)
    let r = lcg(12); var placed: [(Double, Double, Double)] = []
    var tries = 0
    while placed.count < 34 && tries < 8000 {
        tries += 1
        let sz = 8 + 7 * r(), x = r() * Double(TW), y = r() * Double(TH)
        if placed.contains(where: { hypot($0.0 - x, $0.1 - y) < ($0.2 + sz) * 0.95 }) { continue }
        placed.append((x, y, sz))
        let rot = r() * .pi / 3, kind = Int(r() * 2), lw = max(1.4, sz * 0.13)
        func seg(_ a: CGPoint, _ b: CGPoint) { ctx.move(to: a); ctx.addLine(to: b) }
        let S = Double(SS), c = CGPoint(x: x * S, y: Double(h) - y * S)
        func at(_ len: Double, _ ang: Double, from p: CGPoint) -> CGPoint { CGPoint(x: p.x + len * S * cos(ang), y: p.y + len * S * sin(ang)) }
        ctx.setLineWidth(lw * S)
        for k in 0..<6 {
            let a = rot + Double(k) * .pi / 3
            seg(c, at(sz, a, from: c))
            for (f, bl) in [(0.42, 0.34), (0.70, 0.24)] {
                let p = at(sz * f, a, from: c)
                seg(p, at(sz * bl, a + .pi / 3, from: p)); seg(p, at(sz * bl, a - .pi / 3, from: p))
            }
        }
        ctx.strokePath()
        if kind == 1 {   // plate type: a hexagon ring at the centre
            ctx.setLineWidth(lw * 0.8 * S)
            for k in 0...6 { let p = at(sz * 0.26, rot + Double(k) * .pi / 3, from: c); if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } }
            ctx.strokePath()
        }
    }
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
    var cov = [Double](repeating: 0, count: TW * TH)
    for y in 0..<h { for x in 0..<w { cov[(y / SS) * TW + x / SS] += Double(px[y * w + x]) } }
    let t = cov.map { $0 / (Double(SS * SS) * 255) }
    return pickLevels(t, [0x000055, 0x5555AA, 0xFFFFFF].map(idx))   // crisp: coverage snaps to 3 levels, no dither
}
func texFog() -> [Int] {
    // a dense bank rising over most of the bottom digits, solid body, dithered only in its soft top and a few wisps above
    var t = [Double](repeating: 0, count: TW * TH)
    let M = (TH - H) / 2
    for y in 0..<TH { for x in 0..<TW {
        let ys = Double(y - M), X = Double(x)
        let edge = ROW_TOP[1] + 11 + 22 * (fbm(X * 0.022, ys * 0.02, 55, 3) - 0.5) * 2
        var f = max(0, min(1, (ys - edge) / 34))
        let wisp = max(0, sin(ys * 0.35 + 5 * fbm(X * 0.015, ys * 0.04, 56, 3)))
        f = max(f, 0.6 * pow(wisp, 3) * max(0, min(1, (ys - edge + 40) / 40)))   // tendrils drifting above the bank
        t[y * TW + x] = f
    } }
    return ditherRamp(t, [0x000055, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1.0)
}
// NASA SDO/AIA 304: zoomed onto the sun's north limb so the arc crosses the bottom third, prominences rising into black
func texSolar() -> [Int] {
    let img = loadImage("src/sdo.jpg")
    let discCX = 2048.0, discTop = 455.0
    let cw = Double(ENV["SUNW"] ?? "1500")!, scale = Double(TW) / cw, M = Double((TH - H) / 2)
    let limbY = Double(ENV["SUNY"] ?? "138")!          // screen y where the limb sits
    let cy = discTop - (limbY + M) / scale, ch = cw * Double(TH) / Double(TW)
    var l = sampleCrop(img, cx: discCX - cw / 2, cy: cy, cw: cw, ch: ch)
    let bl = boxBlur(l, 1)
    for i in 0..<l.count { l[i] = l[i] + 0.6 * (l[i] - bl[i]) }
    let p98 = l.sorted()[l.count * 98 / 100], g = Double(ENV["SUNG"] ?? "0.6")!
    let t = l.map { max(0, min(1, pow(max(0, ($0 - 0.02) / (p98 - 0.02)), g))) }
    return ditherRamp(t, [0x000000, 0xAA0000, 0xFF5500, 0xFFAA00].map(idx), method: "atkinson", strength: 1)
}

// rotated crop: put a chosen limb point at (centre x, limbY) with the disc's outward normal pointing up the screen
func texSolarRot() -> [Int] {
    let img = loadImage("src/sdo.jpg"), iw = img.width, ih = img.height
    var rgba = [UInt8](repeating: 0, count: iw * ih * 4)
    let c = CGContext(data: &rgba, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: iw * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: iw, height: ih))
    func lum(_ x: Int, _ y: Int) -> Double {
        if x < 0 || y < 0 || x >= iw || y >= ih { return 0 }
        let o = (y * iw + x) * 4; return (0.299 * Double(rgba[o]) + 0.587 * Double(rgba[o + 1]) + 0.114 * Double(rgba[o + 2])) / 255
    }
    let cx0 = 2048.0, cy0 = 2048.0, R = 1593.0
    let ang = Double(ENV["SUNA"] ?? "168.9")! * .pi / 180          // direction from disc centre to the chosen limb point
    let n = (cos(ang), sin(ang)), t = (-n.1, n.0)
    let P = (cx0 + R * n.0, cy0 + R * n.1)
    let cw = Double(ENV["SUNW"] ?? "2200")! * (Double(TW) / REF_TW), scale = Double(TW) / cw, M = Double((TH - H) / 2)
    let U0 = Double(TW) / 2, V0 = Double(ENV["SUNY"] ?? "150")! + M
    var l = [Double](repeating: 0, count: TW * TH), hgt = l
    for v in 0..<TH { for u in 0..<TW {
        var acc = 0.0
        for sy in 0..<3 { for sx in 0..<3 {
            let dx = (Double(u) + (Double(sx) + 0.5) / 3 - U0) / scale, dy = (Double(v) + (Double(sy) + 0.5) / 3 - V0) / scale
            let X = P.0 + dx * t.0 - dy * n.0, Y = P.1 + dx * t.1 - dy * n.1
            acc += lum(Int(X), Int(Y))
        } }
        l[v * TW + u] = acc / 9
        // height above the limb, in screen px, for the corona glow
        let dx = (Double(u) + 0.5 - U0) / scale, dy = (Double(v) + 0.5 - V0) / scale
        let X = P.0 + dx * t.0 - dy * n.0, Y = P.1 + dx * t.1 - dy * n.1
        hgt[v * TW + u] = (hypot(X - cx0, Y - cy0) - R) * scale
    } }
    let bl = boxBlur(l, 1)
    for i in 0..<l.count { l[i] = l[i] + 0.6 * (l[i] - bl[i]) }
    let p98 = l.sorted()[l.count * 98 / 100], g = Double(ENV["SUNG"] ?? "0.5")!, cg = Double(ENV["CORONA"] ?? "0.42")!
    let tt = (0..<l.count).map { i -> Double in
        let v = max(0, min(1, pow(max(0, (l[i] - 0.015) / (p98 - 0.015)), g)))
        let h = hgt[i]
        return h > 0 ? max(v, cg * exp(-h / 34)) : v      // red corona haze fading up into black
    }
    return ditherRamp(tt, [0x000000, 0xAA0000, 0xFF5500, 0xFFAA00].map(idx), method: "atkinson", strength: 1)
}

func texPartlySDO() -> [Int] {
    let base = texSolarRot(), c = mackerel()
    return (0..<base.count).map { i in c[i] > 0.72 ? idx(0xAAAAAA) : (c[i] > 0.64 ? idx(0x555555) : base[i]) }
}

// subdued snow: delicate grey dendrites resting on grey glass, a few soft out-of-focus flakes behind
func texSnowGrey() -> [Int] {
    let w = TW * SS, h = TH * SS
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let r = lcg(77); var placed: [(Double, Double, Double)] = []; var tries = 0
    let S = Double(SS)
    let crystals = perArea(40)
    while placed.count < crystals && tries < 9000 {
        tries += 1
        let sz = 5 + 9 * pow(r(), 1.4), x = r() * Double(TW), y = r() * Double(TH)
        if placed.contains(where: { hypot($0.0 - x, $0.1 - y) < ($0.2 + sz) * 0.9 }) { continue }
        placed.append((x, y, sz))
        let rot = r() * .pi / 3, c = CGPoint(x: x * S, y: Double(h) - y * S)
        func at(_ len: Double, _ ang: Double, from p: CGPoint) -> CGPoint { CGPoint(x: p.x + len * S * cos(ang), y: p.y + len * S * sin(ang)) }
        ctx.setLineWidth(max(1.0, sz * 0.085) * S)
        for k in 0..<6 {
            let a = rot + Double(k) * .pi / 3
            ctx.move(to: c); ctx.addLine(to: at(sz, a, from: c))
            for (f, bl) in [(0.30, 0.22), (0.52, 0.30), (0.74, 0.20)] where sz > 7 || f > 0.5 {
                let p = at(sz * f, a, from: c)
                ctx.move(to: p); ctx.addLine(to: at(sz * bl, a + .pi / 3, from: p))
                ctx.move(to: p); ctx.addLine(to: at(sz * bl, a - .pi / 3, from: p))
            }
        }
        ctx.strokePath()
    }
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
    var cov = [Double](repeating: 0, count: TW * TH)
    for y in 0..<h { for x in 0..<w { cov[(y / SS) * TW + x / SS] += Double(px[y * w + x]) } }
    // soft blurred flakes further away: faint discs that only lift the glass a little
    var soft = [Double](repeating: 0, count: TW * TH)
    for _ in 0..<perArea(26) {
        let x = r() * Double(TW), y = r() * Double(TH), rad = 3 + 4 * r()
        stampMax(&soft, x, y, rad + 1) { dx, dy in max(0, min(1, rad - hypot(dx, dy))) * 0.3 }
    }
    let t = (0..<cov.count).map { i -> Double in
        let c = cov[i] / (Double(SS * SS) * 255)
        return max(soft[i], c >= 0.45 ? 0.5 : 0) }   // crystals snap to #AAAAAA; soft flakes dither faintly
    return ditherRamp(t, [0x555555, 0xAAAAAA, 0xFFFFFF].map(idx), method: "atkinson", strength: 0.9)
}

// colour photo -> small chosen palette, Atkinson error diffusion in RGB
func sampleCropRGB(_ img: CGImage, cx: Double, cy: Double, cw: Double, ch: Double) -> [(Double, Double, Double)] {
    var bytes = [UInt8](repeating: 0, count: TW * TH * 4)
    let ctx = CGContext(data: &bytes, width: TW, height: TH, bitsPerComponent: 8, bytesPerRow: TW * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = Double(TW) / cw, iw = Double(img.width), ih = Double(img.height)
    ctx.draw(img, in: CGRect(x: -cx * s, y: -(ih - (cy + ch)) * s, width: iw * s, height: ih * s))
    return (0..<(TW * TH)).map { (Double(bytes[$0 * 4]), Double(bytes[$0 * 4 + 1]), Double(bytes[$0 * 4 + 2])) }
}
func ditherRGB(_ src: [(Double, Double, Double)], _ pal: [Int], strength: Double) -> [Int] {
    var e = src.map { [$0.0, $0.1, $0.2] }
    let pc = pal.map { rgb($0) }
    var out = [Int](repeating: pal[0], count: TW * TH)
    func add(_ x: Int, _ y: Int, _ d: [Double]) { if x >= 0 && x < TW && y < TH { for k in 0..<3 { e[y * TW + x][k] += d[k] } } }
    for y in 0..<TH { for x in 0..<TW {
        let v = e[y * TW + x]; var best = 0, bd = Double.infinity
        for (k, c) in pc.enumerated() { let d = weightedDist((v[0], v[1], v[2]), c); if d < bd { bd = d; best = k } }
        out[y * TW + x] = pal[best]
        let c = pc[best], q = [(v[0] - c.0) * strength / 8, (v[1] - c.1) * strength / 8, (v[2] - c.2) * strength / 8]
        add(x + 1, y, q); add(x + 2, y, q); add(x - 1, y + 1, q); add(x, y + 1, q); add(x + 1, y + 1, q); add(x, y + 2, q)
    } }
    return out
}
func texSunClouds() -> [Int] {
    let img = loadImage("src/sunclouds.jpg")
    let cw = Double(ENV["PCW"] ?? "1500")!, ch = cw * Double(TH) / Double(TW)
    let cx = Double(ENV["PCX"] ?? "1064")!, cy = Double(ENV["PCY"] ?? "444")!
    let g = Double(ENV["PCG"] ?? "0.82")!
    let src = sampleCropRGB(img, cx: cx, cy: cy, cw: cw, ch: ch).map { ($0.0 * g, $0.1 * g, $0.2 * g) }
    return ditherRGB(src, [0x0055AA, 0x55AAFF, 0x5555AA, 0xAAAAFF, 0xFFFFFF].map(idx), strength: 0.85)
}

func texSunClouds2() -> [Int] {
    let img = loadImage("src/sunclouds.jpg")
    let cw = Double(ENV["PCW"] ?? "1500")!, ch = cw * Double(TH) / Double(TW)
    let cx = Double(ENV["PCX"] ?? "1064")!, cy = Double(ENV["PCY"] ?? "300")!, g = Double(ENV["PCG"] ?? "1.0")!
    let l = sampleCrop(img, cx: cx, cy: cy, cw: cw, ch: ch).map { $0 * g }
    let ramp = [0x0055AA, 0x55AAFF, 0xAAAAFF, 0xFFFFFF].map(idx)
    let lv = ramp.map(lumOf), lo = lv.first!, hi = lv.last!, sky = lv[1]
    let t = l.map { v -> Double in
        let a = abs(v - sky) < Double(ENV["PCS"] ?? "0.035")! ? sky : v      // plain sky lands exactly on #55AAFF
        return max(0, min(1, (a - lo) / (hi - lo))) }
    return ditherRamp(t, ramp, method: "atkinson", strength: 0.9)
}

// front-lit fair-weather cumulus: flat deep-blue sky, white puffs with grey-blue shading
func texCumulus() -> [Int] {
    let img = loadImage("src/clouds.jpg")
    let iw = Double(img.width)
    let fw = Double(ENV["CUW"] ?? "0.5")!
    let c = fitCrop(cx: iw * Double(ENV["CUX"] ?? "0.25")!, cy: Double(img.height) * Double(ENV["CUY"] ?? "0.1")!, cw: iw * fw,
                    iw: iw, ih: Double(img.height))
    var l = sampleCrop(img, cx: c.cx, cy: c.cy, cw: c.cw, ch: c.ch)
    let bl = boxBlur(l, 1)
    for i in 0..<l.count { l[i] = l[i] + 0.5 * (l[i] - bl[i]) }
    let so = l.sorted(), p2 = so[l.count / 50], p98 = so[l.count * 49 / 50], ts = Double(ENV["CUT"] ?? "0.38")!
    let t = l.map { v -> Double in
        let n = max(0, min(1, (v - p2) / (p98 - p2)))
        return n < ts ? 0 : 0.25 + 0.75 * (n - ts) / (1 - ts)     // open sky snaps flat; clouds span shading to white
    }
    return ditherRamp(t, CLOUD_RAMP.map(idx), method: "atkinson", strength: 0.8)
}

func texCloudyBlue() -> [Int] {
    let c = mackerel(), ts = Double(ENV["CLT"] ?? "0.22")!
    let t = c.map { n -> Double in n < ts ? 0 : 0.25 + 0.75 * (n - ts) / (1 - ts) }
    return ditherRamp(t, CLOUD_RAMP.map(idx), method: "atkinson", strength: 0.8)
}
// depth pass on a finished 1x day frame: recess shading inside the windows + a bevelled cut edge on the plate
let BAYER4: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]].map { $0.map { ($0 + 0.5) / 16 } }
func darkenStep(_ i: Int) -> Int { let r = i / 16, g = i / 4 % 4, b = i % 4; return max(r - 1, 0) * 16 + max(g - 1, 0) * 4 + max(b - 1, 0) }
func depthPass(_ fr: [Int], win: [UInt8], plate: Int) -> [Int] {
    let cov = coverage(win), dist = insideDistance(win)
    let reach = Double(ENV["AOR"] ?? "5")!
    var out = fr
    for y in 0..<H { for x in 0..<W {
        let i = y * W + x
        if cov[i] >= 0.5 {
            let d = dist[i]
            if d <= 1.5 { out[i] = darkenStep(fr[i]); continue }                       // solid inner edge
            let f = max(0, 1 - (d - 1.5) / reach)                                      // soft falloff, ordered dither
            if f > BAYER4[y & 3][x & 3] { out[i] = darkenStep(fr[i]) }
        } else if ENV["BEVEL"] != "0" && y > 0 && x > 0 && y < H - 1 && x < W - 1 {
            let inWin = { (dx: Int, dy: Int) -> Bool in cov[(y + dy) * W + x + dx] >= 0.5 }
            if inWin(-1, 0) || inWin(0, -1) { out[i] = idx(0xFFFFFF) }                 // rim facing the light
            if inWin(1, 0) || inWin(0, 1) { out[i] = idx(0xAAAA55) }                   // rim in shade
        }
    } }
    return out
}

let WX2: [String: () -> [Int]] = ["sunny": texSolarRot, "sunny-top": texSolar, "sunny-old": texSunny, "partly": texCumulus, "partly-backlit": texSunClouds2, "partly-rgb": texSunClouds, "partly-sdo": texPartlySDO, "partly-old": texPartly, "cloudy": texCloudyBlue, "cloudy-grey": texCloudy, "snow": texSnowGrey, "snow-bold": texSnowflakes, "fog": texFog]

// night skies: same clouds, navy sky, moonlit silver-grey instead of sunlit white
let NIGHT_CLOUD_RAMP = [0x000055, 0x555555, 0x5555AA, 0xAAAAAA]
func withNightClouds(_ f: () -> [Int]) -> [Int] { let keep = CLOUD_RAMP; CLOUD_RAMP = NIGHT_CLOUD_RAMP; defer { CLOUD_RAMP = keep }; return f() }
let NIGHT_TEX: [String: () -> [Int]] = ["partly": { withNightClouds(texCumulus) }, "cloudy": { withNightClouds(texCloudyBlue) }]

// day plate = the sky: time-of-day tint + a soft glow and small disc where the sun really is
func skyPlate(base: Int, glow: [Int], sunX: Double, sunY: Double) -> [Int] {
    var t = [Double](repeating: 0, count: W * H)
    for y in 0..<H { for x in 0..<W {
        let d = hypot(Double(x) + 0.5 - sunX, Double(y) + 0.5 - sunY)
        t[y * W + x] = d < 11 ? 1 : max(0, min(1, 0.95 * exp(-(d - 11) / 38)))
    } }
    let keepTW = TW, keepTH = TH; TW = W; TH = H
    defer { TW = keepTW; TH = keepTH }
    return ditherRamp(t, ([base] + glow).map(idx), method: "atkinson", strength: 0.9)
}
let SKY_TIMES: [(String, Int, [Int], Double, Double)] = [
    ("morning",   0xFFAAAA, [0xFFFFAA, 0xFFFFFF], 26, 200),
    ("noon",      0xAAFFFF, [0xFFFFFF],           100, 26),
    ("afternoon", 0xFFFFAA, [0xFFFFFF],           165, 70),
    ("golden",    0xFFAA55, [0xFFFF55, 0xFFFFAA], 182, 206),
]

// day plate v2: vertical sky gradient (deeper overhead, pale at the horizon) + a wide bloom around the real sun; canvas-sized for tilt
struct SkyTime { let name: String; let ramp: [Int]; let sunX: Double; let sunY: Double }
let SKY2: [SkyTime] = [
    SkyTime(name: "morning",   ramp: [0xAAAAFF, 0xFFAAAA, 0xFFFFAA, 0xFFFFFF], sunX: 18,  sunY: 196),
    SkyTime(name: "noon",      ramp: [0x55AAFF, 0xAAFFFF, 0xFFFFFF],           sunX: 100, sunY: 6),
    SkyTime(name: "afternoon", ramp: [0x55AAFF, 0xAAFFFF, 0xFFFFAA, 0xFFFFFF], sunX: 176, sunY: 64),
    SkyTime(name: "golden",    ramp: [0xFF5555, 0xFFAA55, 0xFFFF55, 0xFFFFAA], sunX: 184, sunY: 212),
]
func skyPlate2(_ st: SkyTime, margin M: Int, glow: Bool) -> [Int] {
    var t = [Double](repeating: 0, count: TW * TH)
    for y in 0..<TH { for x in 0..<TW {
        let ys = Double(y - M), xs = Double(x - M)
        let grad = 0.55 * pow(max(0, min(1, ys / Double(H))), 1.3)
        var v = grad
        if glow {
            let d = hypot(xs + 0.5 - st.sunX, ys + 0.5 - st.sunY)
            let bloom = d < 12 ? 1.0 : 0.97 * exp(-(d - 12) / 62)
            v = 1 - (1 - grad) * (1 - bloom)
        }
        t[y * TW + x] = max(0, min(1, v))
    } }
    return ditherRamp(t, st.ramp.map(idx), method: "atkinson", strength: 0.9)
}

// fix 1: terraced sky - flat bands that land exactly on palette colours, dither only in narrow seams
func terrace(_ t: [Double], _ ramp: [Int], seam: Double) -> [Double] {
    let lv = ramp.map(lumOf), lo = lv.first!, hi = lv.last!
    let tk = lv.map { ($0 - lo) / (hi - lo) }
    return t.map { v in
        var k = 0; while k + 1 < tk.count - 1 && v > tk[k + 1] { k += 1 }
        let a = tk[k], b = tk[k + 1], u = max(0, min(1, (v - a) / (b - a)))
        let e = max(0, min(1, (u - (0.5 - seam)) / (2 * seam))); let sm = e * e * (3 - 2 * e)
        return a + sm * (b - a)
    }
}
// fix 2: weather-aware sky tints - blue/white weathers get a warm pale sky, orange (sunny) gets a cool or pale-gold sky
func skyRamp(_ time: String, _ weather: String) -> [Int] {
    let skyish: Set<String> = ["partly", "cloudy"]
    if skyish.contains(weather) {
        switch time {
        case "morning": return [0xFFAAAA, 0xFFFFAA, 0xFFFFFF]
        case "golden":  return [0xFFAA55, 0xFFFF55, 0xFFFFAA]
        default:        return [0xFFFFAA, 0xFFFFFF]
        }
    }
    if weather == "sunny" {
        switch time {
        case "golden":  return [0xFFFF55, 0xFFFFAA, 0xFFFFFF]
        case "morning": return [0xAAAAFF, 0xAAFFFF, 0xFFFFFF]
        default:        return [0x55AAFF, 0xAAFFFF, 0xFFFFFF]
        }
    }
    return SKY2.first { $0.name == time }!.ramp
}
func skyPlate3(_ st: SkyTime, ramp: [Int], margin M: Int, glow: Bool) -> [Int] {
    // the gradient runs fully from the top colour to the next one, so it becomes two flat bands and one seam
    let lv = ramp.map(lumOf), tk = lv.map { ($0 - lv[0]) / (lv.last! - lv[0]) }
    let gmax = ramp.count >= 4 ? tk[2] : tk[1]    // end the gradient exactly on a band so the horizon is flat
    var t = [Double](repeating: 0, count: TW * TH)
    for y in 0..<TH { for x in 0..<TW {
        let ys = Double(y - M), xs = Double(x - M)
        let grad = gmax * pow(max(0, min(1, ys / Double(H))), 1.3)
        var v = grad
        if glow {
            let d = hypot(xs + 0.5 - st.sunX, ys + 0.5 - st.sunY)
            v = 1 - (1 - grad) * (1 - (d < 12 ? 1.0 : 0.97 * exp(-(d - 12) / Double(ENV["BLOOM"] ?? "44")!)))
        }
        t[y * TW + x] = max(0, min(1, v))
    } }
    return ditherRamp(terrace(t, ramp, seam: Double(ENV["SEAM"] ?? "0.08")!), ramp.map(idx), method: "atkinson", strength: 0.9)
}

let px: [Int]
switch mode {
case "day":
    let plate = idx(0xFFFFAA)
    px = face(h: "08", m: "29", shadow: true, keyline: false, base: K_BLACK, topFill: idx(0x00AA00), botFill: idx(0x0055FF),
              steps: 0.45, battery: 0.70, bg: { _, _ in plate }, shadowCol: idx(0xAAAA55))
case "night":
    px = face(h: "21", m: "30", shadow: false, keyline: true, base: K_WHITE, topFill: idx(0x55FF55), botFill: idx(0x55AAFF),
              steps: 0.45, battery: 0.70, bg: moonSample, shadowCol: 0)
case "nightinv":
    px = face(h: "21", m: "30", shadow: false, keyline: false, base: K_WHITE, topFill: idx(0x55FF55), botFill: idx(0x55AAFF),
              steps: 0.45, battery: 0.70, bg: moonSample, shadowCol: 0, invert: moonLit)
case "cut-sun": px = cutout(h: "08", m: "29", scene: sceneSun, plate: K_BLACK)
case "cut-cloud": px = cutout(h: "11", m: "40", scene: sceneCloud, plate: K_BLACK)
case "cut-rain": px = cutout(h: "15", m: "05", scene: sceneRain, plate: K_BLACK)
case "snight":
    if args.count > 5 { PHASE_E = Double(args[4])!; PHASE_WAX = args[5] == "1" }
    px = nightStyl(h: "21", m: "30")
case "sphase":
    PHASE_E = Double(args[4])!; PHASE_WAX = args[5] == "1"
    px = compose(bg: moonStyl, layers: [])
case "w-sunny": px = dayWindow(h: "08", m: "29", scene: sceneSunny, sky: idx(0x0055FF), tileW: 30, tileH: 26)
case "w-rain": px = dayWindow(h: "15", m: "05", scene: sceneDrops, sky: idx(0x555555), tileW: 26, tileH: 28)
case "w-storm": px = dayWindow(h: "17", m: "42", scene: sceneStorm, sky: idx(0x000055), tileW: 26, tileH: 30)
case "pmoon":   // args: method strength
    px = ditherRamp(moonTone(), GREY4, method: args[4], strength: Double(args[5])!)
case "pmoonface": // args: method strength rampHexes(comma) digitHex
    let ramp = args[6].split(separator: ",").map { idx(Int($0, radix: 16)!) }
    let bgi = ditherRamp(moonTone(), ramp, method: args[4], strength: Double(args[5])!)
    px = photoFace(bgIdx: bgi, h: "21", m: "30", digit: idx(Int(args[7], radix: 16)!), shadow: false, window: false)
case "pdrops": // args: file fx fy fw method strength rampHexes
    let ramp = args[10].split(separator: ",").map { idx(Int($0, radix: 16)!) }
    let bgi = ditherRamp(dropsTone(args[4], fx: Double(args[5])!, fy: Double(args[6])!, fw: Double(args[7])!), ramp, method: args[8], strength: Double(args[9])!)
    px = args.count > 11 ? photoFace(bgIdx: bgi, h: "15", m: "05", digit: 0, shadow: true, window: true,
                                     plate: idx(Int(ENV["PLATE"] ?? "FFFFAA", radix: 16)!), shade: idx(Int(ENV["SHADE"] ?? "AAAA55", radix: 16)!)) : bgi
case "pnightrain": // moon seen through wet glass. args: digitHex rampHexes
    let moon = boxBlur(moonTone(), Int(ENV["RB"] ?? "1")!)
    let drops = dropsTone("src/drops_grey.jpg", fx: 0.2, fy: 0.0, fw: Double(ENV["RF"] ?? "0.5")!)
    let rm = Double(ENV["RM"] ?? "0.8")!, rw = Double(ENV["RW"] ?? "0.9")!, lift = Double(ENV["RL"] ?? "0")!
    let mix = (0..<(W * H)).map { i in max(0, min(1, moon[i] * rm + (drops[i] - 0.5) * rw + lift)) }
    let ramp = args[5].split(separator: ",").map { idx(Int($0, radix: 16)!) }
    let bgi = ditherRamp(mix, ramp, method: "atkinson", strength: 1)
    px = photoFace(bgIdx: bgi, h: "21", m: "30", digit: idx(Int(args[4], radix: 16)!), shadow: false, window: false)
case "pday": // args: kind rampHexes h m
    let t = args[4] == "clouds" ? cloudsT() : frostT()
    let ramp = args[5].split(separator: ",").map { idx(Int($0, radix: 16)!) }
    let bgi = ditherRamp(t, ramp, method: "atkinson", strength: 1)
    let f = digitFont()
    let top = layoutRow(f, args[6], top: 9, digitH: digitH, centreX: 106)
    let bot = layoutRow(f, args[7], top: 121, digitH: digitH, centreX: 106)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    px = compose(bg: { _, _ in idx(0xFFFFAA) }, layers: [Layer(mask: sweep(win, dx: -12, dy: 4), colour: { _, _ in idx(0xAAAA55) }),
                                                        Layer(mask: win, colour: { hx, hy in bgi[(hy / SS) * W + hx / SS] })])
case "pnight": // args: kind  -> weather in front of the big moon, warm digits
    let moon = moonTone()
    var mix = [Double](repeating: 0, count: W * H)
    if args[4] == "clouds" {
        let c = cloudsT()
        let k0 = Double(ENV["C0"] ?? "0.35")!, k1 = Double(ENV["C1"] ?? "0.75")!, cover = Double(ENV["CC"] ?? "0.85")!, grey = Double(ENV["CG"] ?? "0.3")!
        for i in 0..<(W * H) { let cv = smooth(k0, k1, c[i]); mix[i] = moon[i] * (1 - cover * cv) + grey * cv * c[i] }
    } else {
        let fr = frostT(), fm = Double(ENV["FM"] ?? "0.7")!, fw = Double(ENV["FW"] ?? "0.5")!
        for i in 0..<(W * H) { mix[i] = max(0, min(1, moon[i] * fm + fr[i] * fw)) }
    }
    let bgi = ditherRamp(mix.map { max(0, min(1, $0)) }, [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    px = photoFace(bgIdx: bgi, h: "21", m: "30", digit: idx(0xFFFFAA), shadow: false, window: false)
case "plit": // backlight on: glass wiped (crisp moon) + one detail line in the gutter
    let bgi = ditherRamp(moonTone(), [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    let f = digitFont()
    let top = layoutRow(f, "21", top: 9, digitH: digitH, centreX: 100)
    let bot = layoutRow(f, "30", top: 121, digitH: digitH, centreX: 100)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    let txt = textMask(args[4], size: 12, centreX: 100, baseline: 118.5)
    // a black band behind the line so it reads over the moon
    let band = render([CGPath(rect: CGRect(x: 0, y: Double(HH) - 121 * Double(SS), width: Double(HW), height: 14 * Double(SS)), transform: nil)])
    px = compose(bg: { hx, hy in bgi[(hy / SS) * W + hx / SS] }, layers: [Layer(mask: band, colour: { _, _ in 0 }),
        Layer(mask: win, colour: { _, _ in idx(0xFFFFAA) }), Layer(mask: txt, colour: { _, _ in idx(0xFFFFAA) })])
case "anim-rain-day":
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    let tex = ditherRamp(dropsTone("src/drops_grey.jpg", fx: 0.15, fy: 0.0, fw: 0.58), [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    TW = W; TH = H
    let f = digitFont()
    let top = layoutRow(f, "15", top: 9, digitH: digitH, centreX: 106), bot = layoutRow(f, "05", top: 121, digitH: digitH, centreX: 106)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) }), sh = sweep(win, dx: -12, dy: 4)
    let n = 48; var frames: [[Int]] = []
    for fi in 0..<n {
        let (ox, oy) = tilt(fi, n, 13, 9)
        frames.append(compose(bg: { _, _ in idx(0xFFFFAA) }, layers: [Layer(mask: sh, colour: { _, _ in idx(0xAAAA55) }),
            Layer(mask: win, colour: { hx, hy in tex[(hy / SS + M + oy) * (W + 2 * M) + hx / SS + M + ox] })]))
    }
    writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.06); px = frames[0]
case "anim-snow-night":
    let M = 5; TW = W + 2 * M; TH = H + 2 * M
    let moon = ditherRamp(moonTone(), [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    TW = W; TH = H
    let f = digitFont()
    let top = layoutRow(f, "21", top: 9, digitH: digitH, centreX: 100), bot = layoutRow(f, "30", top: 121, digitH: digitH, centreX: 100)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    let flakes = makeFlakes(34, seed: 5)
    let n = 48; var frames: [[Int]] = []
    for fi in 0..<n {
        let (tx, ty) = tilt(fi, n, 12, 8)
        var bg = [Int](repeating: 0, count: W * H)
        let mx = Int((Double(tx) * 0.3).rounded()), my = Int((Double(ty) * 0.3).rounded())   // the moon is far away: moves least
        for y in 0..<H { for x in 0..<W { bg[y * W + x] = moon[(y + M + my) * (W + 2 * M) + x + M + mx] } }
        drawFlakes(&bg, flakes, fi, n, tx, ty, colours: [idx(0x555555), idx(0xAAAAAA), idx(0xFFFFFF)])
        frames.append(compose(bg: { hx, hy in bg[(hy / SS) * W + hx / SS] }, layers: [Layer(mask: win, colour: { _, _ in idx(0xFFFFAA) })]))
    }
    writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.06); px = frames[0]
case "anim-snow-day":
    let f = digitFont()
    let top = layoutRow(f, "08", top: 9, digitH: digitH, centreX: 106), bot = layoutRow(f, "29", top: 121, digitH: digitH, centreX: 106)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) }), sh = sweep(win, dx: -12, dy: 4)
    let flakes = makeFlakes(60, seed: 9)
    let n = 48; var frames: [[Int]] = []
    for fi in 0..<n {
        let (tx, ty) = tilt(fi, n, 12, 8)
        var sky = [Int](repeating: idx(0x0055AA), count: W * H)
        drawFlakes(&sky, flakes, fi, n, tx, ty, colours: [idx(0x55AAFF), idx(0xAAFFFF), idx(0xFFFFFF)])
        frames.append(compose(bg: { _, _ in idx(0xFFFFAA) }, layers: [Layer(mask: sh, colour: { _, _ in idx(0xAAAA55) }),
            Layer(mask: win, colour: { hx, hy in sky[(hy / SS) * W + hx / SS] })]))
    }
    writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.06); px = frames[0]
case "carved-day":
    let M = 12; TW = W + 2 * M; TH = H + 2 * M
    let tex = ditherRamp(dropsTone("src/drops_grey.jpg", fx: 0.15, fy: 0.0, fw: 0.58), [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    TW = W; TH = H
    let f = digitFont()
    let top = layoutRow(f, "15", top: 9, digitH: digitH, centreX: 100), bot = layoutRow(f, "05", top: 121, digitH: digitH, centreX: 100)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    let plateM = win.map { 255 - $0 }
    // sunlight travels west-south-west; the plate's silhouette lands 7px along it on the floor
    let psf = shifted(plateM, -7 * SS, 3 * SS)
    let n = 48; var frames: [[Int]] = []
    for fi in 0..<n {
        let (ox, oy) = tilt(fi, n, 5, 4)
        frames.append(carvedFrame(win: win, plateShadowFloor: psf, tex: tex, texW: W + 2 * M, margin: M, ox: ox, oy: oy,
                                  plate: idx(0xFFFFAA), wall: idx(0xAAAA55)))
    }
    writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.06); px = frames[0]
case "carved-night":
    let M = 12
    TW = W + 2 * M; TH = H + 2 * M
    let td = dropsTone("src/drops_grey.jpg", fx: 0.15, fy: 0.0, fw: 0.58)
    let dim = ditherRamp(td, [0x000000, 0x000055, 0x0055AA].map(idx), method: "atkinson", strength: 1)
    let lit = ditherRamp(td, [0xAA5500, 0xFFAA55, 0xFFFFAA].map(idx), method: "atkinson", strength: 1)
    let mid = ditherRamp(td, [0x550000, 0xAA5500, 0xFFAA55].map(idx), method: "atkinson", strength: 1)
    TW = W; TH = H
    let moon = ditherRamp(moonTone(), [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    let f = digitFont()
    let top = layoutRow(f, "21", top: 9, digitH: digitH, centreX: 100), bot = layoutRow(f, "30", top: 121, digitH: digitH, centreX: 100)
    let paths = (top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) }
    let win = render(paths), frameM = render(paths, stroke: CGFloat(4 * SS))
    let plateM = win.map { 255 - $0 }
    let psf = shifted(plateM, 5 * SS, -2 * SS)   // moonlight from the west-north-west: shadow falls the other way
    var frames: [[Int]] = []
    func add(_ tex: [Int], _ fc: Int, _ ox: Int, _ oy: Int, _ wall: Int) {
        let bgMoon: [Int] = moon
        let fr = carvedFrame(win: win, plateShadowFloor: psf, tex: tex, texW: W + 2 * M, margin: M, ox: ox, oy: oy,
                             plate: 0, wall: wall, frame: frameM, frameCol: fc)
        // plate = the moonlit sky: put the moon wherever the plate shows
        frames.append((0..<(W * H)).map { i in fr[i] == 0 && win[(i / W) * SS * HW + (i % W) * SS] < 128 ? bgMoon[i] : fr[i] })
    }
    for _ in 0..<14 { add(dim, idx(0xFFAA55), 0, 0, idx(0x000055)) }            // unlit: dim windows, warm frames
    add(mid, idx(0xFFFFAA), 0, 0, idx(0x550000))                                // light coming on
    let n = 40
    for fi in 0..<n { let (ox, oy) = tilt(fi, n, 5, 4); add(lit, idx(0xFFFFAA), ox, oy, idx(0xAA5500)) }
    add(mid, idx(0xFFFFAA), 0, 0, idx(0x550000))                                // fade
    writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.07); px = frames[0]; writePNG(frames[20], prefix + "_lit_4x.png", scale: 4)
case "cut-day":
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    let tex = ditherRamp(dropsTone("src/drops_grey.jpg", fx: 0.15, fy: 0.0, fw: 0.58), [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    TW = W; TH = H
    let f = digitFont()
    let top = layoutRow(f, "15", top: 9, digitH: digitH, centreX: 100), bot = layoutRow(f, "05", top: 121, digitH: digitH, centreX: 100)
    let win = render((top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    let n = 48; var frames: [[Int]] = []
    for fi in 0..<n {
        let (ox, oy) = tilt(fi, n, 13, 9)
        frames.append(compose(bg: { _, _ in idx(0xFFFFAA) }, layers: [Layer(mask: win, colour: { hx, hy in tex[(hy / SS + M + oy) * (W + 2 * M) + hx / SS + M + ox] })]))
    }
    writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.06); px = frames[0]
case "neon-night":
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    let dt = dropsTone("src/drops_grey.jpg", fx: 0.15, fy: 0.0, fw: 0.58)
    let tex = ditherRamp(dt, [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    let texLit = ENV["STEP"] == "1" ? ditherRamp(dt, [0x555555, 0xAAAAAA, 0xFFFFFF].map(idx), method: "atkinson", strength: 1) : tex
    TW = W; TH = H
    let mt = moonTone()
    let moonFull = ditherRamp(mt, [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    let moonDim = ditherRamp(mt, [0x000000, 0x555555].map(idx), method: "atkinson", strength: 1)
    let f = digitFont()
    let top = layoutRow(f, "21", top: 9, digitH: digitH, centreX: 100), bot = layoutRow(f, "30", top: 121, digitH: digitH, centreX: 100)
    let paths = (top + bot).map { gpath(f, $0.g, $0.x, $0.baseline) }
    let win = render(paths)
    let ring = [2.0, 3.5, 5.5].map { render(paths, stroke: CGFloat($0 * 2 * Double(SS))) }   // border, glow, outer glow
    let G = (ENV["GLOW"] ?? "FFFFAA,FFFFAA,AAAA55,555500").split(separator: ",").map { idx(Int($0, radix: 16)!) }
    let G0 = G[0], G1 = G[1], G2 = G[2], G3 = G[3]
    let B1 = 0.0
    func frame(moon: [Int], glow: Bool, ox: Int, oy: Int) -> [Int] {
        var layers: [Layer] = []
        if glow {
            layers.append(Layer(mask: ring[2], colour: { _, _ in G3 }))
            layers.append(Layer(mask: ring[1], colour: { _, _ in G2 }))
        }
        layers.append(Layer(mask: ring[0], colour: { _, _ in glow ? G1 : G0 }))
        let t = glow ? texLit : tex
        layers.append(Layer(mask: win, colour: { hx, hy in t[(hy / SS + M + oy) * (W + 2 * M) + hx / SS + M + ox] }))
        _ = B1
        return compose(bg: { hx, hy in moon[(hy / SS) * W + hx / SS] }, layers: layers)
    }
    var frames: [[Int]] = []
    let unlit = frame(moon: moonFull, glow: false, ox: 0, oy: 0)
    for _ in 0..<16 { frames.append(unlit) }
    frames.append(frame(moon: moonDim, glow: false, ox: 0, oy: 0))
    let n = 44
    for fi in 0..<n { let (ox, oy) = tilt(fi, n, 13, 9); frames.append(frame(moon: moonDim, glow: true, ox: ox, oy: oy)) }
    frames.append(frame(moon: moonDim, glow: false, ox: 0, oy: 0))
    writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.065)
    writePNG(unlit, prefix + "_unlit_4x.png", scale: 4); writePNG(frames[17 + 11], prefix + "_lit_4x.png", scale: 4)
    writePNG(unlit, prefix + "_unlit_1x.png", scale: 1); writePNG(frames[17 + 11], prefix + "_lit_1x.png", scale: 1)
    px = unlit
case "wx":   // args: name -> day, night unlit, night lit frames
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    let texDay: [Int], texLit: [Int]
    if let g = WX2[args[4]] { texDay = g(); texLit = NIGHT_TEX[args[4]]?() ?? texDay } else {
        let spec = WX[args[4]]!, t = spec.tex(), ramp = spec.ramp.map(idx)
        texDay = ditherRamp(t, ramp, method: "atkinson", strength: 1); texLit = texDay }
    TW = W; TH = H
    let mt = moonTone()
    let moonFull = ditherRamp(mt, [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    let moonDim = ditherRamp(mt, [0x000000, 0x555555].map(idx), method: "atkinson", strength: 1)
    let f = digitFont()
    let texAt: ([Int]) -> (Int, Int) -> Int = { tx in { hx, hy in tx[(hy / SS + M) * (W + 2 * M) + hx / SS + M] } }
    let dTop = layoutRow(f, "10", top: 9, digitH: digitH, centreX: 100), dBot = layoutRow(f, "48", top: 121, digitH: digitH, centreX: 100)
    let dWin = render((dTop + dBot).map { gpath(f, $0.g, $0.x, $0.baseline) })
    var day = compose(bg: { _, _ in idx(0xFFFFAA) }, layers: [Layer(mask: dWin, colour: texAt(texDay))])
    if ENV["DEPTH"] == "1" { day = depthPass(day, win: dWin, plate: idx(0xFFFFAA)) }
    let nTop = layoutRow(f, "21", top: 9, digitH: digitH, centreX: 100), nBot = layoutRow(f, "30", top: 121, digitH: digitH, centreX: 100)
    let paths = (nTop + nBot).map { gpath(f, $0.g, $0.x, $0.baseline) }
    let nWin = render(paths), ring = [2.0, 3.5, 5.5].map { render(paths, stroke: CGFloat($0 * 2 * Double(SS))) }
    let moonAt: ([Int]) -> (Int, Int) -> Int = { m in { hx, hy in m[(hy / SS) * W + hx / SS] } }
    let unlit = compose(bg: moonAt(moonFull), layers: [Layer(mask: ring[0], colour: { _, _ in idx(0x55FFFF) }), Layer(mask: nWin, colour: texAt(texLit))])
    let lit = compose(bg: moonAt(moonDim), layers: [Layer(mask: ring[2], colour: { _, _ in idx(0x005555) }), Layer(mask: ring[1], colour: { _, _ in idx(0x00AAAA) }),
                                                  Layer(mask: ring[0], colour: { _, _ in idx(0xAAFFFF) }), Layer(mask: nWin, colour: texAt(texLit))])
    for (nm, fr) in [("day", day), ("nu", unlit), ("nl", lit)] { writePNG(fr, prefix + "_" + nm + "_1x.png", scale: 1); writePNG(fr, prefix + "_" + nm + "_4x.png", scale: 4) }
    px = day
case "wxgif":   // args: name -> day parallax gif + night (unlit hold, then lit parallax) gif
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    let texDay: [Int], texLit: [Int]
    if let g = WX2[args[4]] { texDay = g(); texLit = NIGHT_TEX[args[4]]?() ?? texDay } else {
        let spec = WX[args[4]]!, t = spec.tex(), ramp = spec.ramp.map(idx)
        texDay = ditherRamp(t, ramp, method: "atkinson", strength: 1); texLit = texDay }
    ENVMX = M
    let mt = moonTone()
    ENVMX = 0
    let moonFull = ditherRamp(mt, [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    let moonDim = ditherRamp(mt, [0x000000, 0x555555].map(idx), method: "atkinson", strength: 1)
    TW = W; TH = H
    let f = digitFont(), TWm = W + 2 * M
    let dRows = layoutRow(f, "10", top: 9, digitH: digitH, centreX: 100) + layoutRow(f, "48", top: 121, digitH: digitH, centreX: 100)
    let dWin = render(dRows.map { gpath(f, $0.g, $0.x, $0.baseline) })
    let nPaths = (layoutRow(f, "21", top: 9, digitH: digitH, centreX: 100) + layoutRow(f, "30", top: 121, digitH: digitH, centreX: 100)).map { gpath(f, $0.g, $0.x, $0.baseline) }
    let nWin = render(nPaths), ring = [2.0, 3.5, 5.5].map { render(nPaths, stroke: CGFloat($0 * 2 * Double(SS))) }
    let n = 44
    var day: [[Int]] = []
    for fi in 0..<n { let (ox, oy) = tilt(fi, n, 13, 9)
        let fr = compose(bg: { _, _ in idx(0xFFFFAA) }, layers: [Layer(mask: dWin, colour: { hx, hy in texDay[(hy / SS + M + oy) * TWm + hx / SS + M + ox] })])
        day.append(ENV["DEPTH"] == "1" ? depthPass(fr, win: dWin, plate: idx(0xFFFFAA)) : fr) }
    writeGIF(day, prefix + "_day.gif", scale: 3, delay: 0.06)
    var night: [[Int]] = []
    let unlit = compose(bg: { hx, hy in moonFull[(hy / SS + M) * TWm + hx / SS + M] }, layers: [Layer(mask: ring[0], colour: { _, _ in idx(0x55FFFF) }),
                        Layer(mask: nWin, colour: { hx, hy in texLit[(hy / SS + M) * TWm + hx / SS + M] })])
    for _ in 0..<14 { night.append(unlit) }
    for fi in 0..<n { let (ox, oy) = tilt(fi, n, 13, 9)
        let mx = 0, my = 0   // the moon only moves on clear nights
        night.append(compose(bg: { hx, hy in moonDim[(hy / SS + M + my) * TWm + hx / SS + M + mx] }, layers: [
            Layer(mask: ring[2], colour: { _, _ in idx(0x005555) }), Layer(mask: ring[1], colour: { _, _ in idx(0x00AAAA) }),
            Layer(mask: ring[0], colour: { _, _ in idx(0xAAFFFF) }),
            Layer(mask: nWin, colour: { hx, hy in texLit[(hy / SS + M + oy) * TWm + hx / SS + M + ox] })])) }
    writeGIF(night, prefix + "_night.gif", scale: 3, delay: 0.065)
    px = day[0]
case "clearnight":   // windows look through to a bright moon; the moon around them stays dimmed
    let M = 12
    TW = W + 2 * M; TH = H + 2 * M
    ENVMX = M
    let mtBig = moonTone()
    ENVMX = 0
    let winUnlit = ditherRamp(mtBig, [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1)
    let winLit = winUnlit   // no brightening at night
    let plateBig = ditherRamp(mtBig, [0x000000, 0x555555].map(idx), method: "atkinson", strength: 1)
    TW = W; TH = H
    let f = digitFont(), TWm = W + 2 * M
    let paths = (layoutRow(f, "21", top: 9, digitH: digitH, centreX: 100) + layoutRow(f, "30", top: 121, digitH: digitH, centreX: 100)).map { gpath(f, $0.g, $0.x, $0.baseline) }
    let win = render(paths), ring = [2.0, 3.5, 5.5].map { render(paths, stroke: CGFloat($0 * 2 * Double(SS))) }
    func plateAt(_ ox: Int, _ oy: Int) -> (Int, Int) -> Int { { hx, hy in plateBig[(hy / SS + M + oy) * TWm + hx / SS + M + ox] } }
    func winAt(_ t: [Int], _ ox: Int, _ oy: Int) -> (Int, Int) -> Int { { hx, hy in t[(hy / SS + M + oy) * TWm + hx / SS + M + ox] } }
    let unlit = compose(bg: plateAt(0, 0), layers: [Layer(mask: ring[0], colour: { _, _ in idx(0x55FFFF) }), Layer(mask: win, colour: winAt(winUnlit, 0, 0))])
    var frames: [[Int]] = Array(repeating: unlit, count: 14)
    let n = 44
    for fi in 0..<n { let (ox, oy) = tilt(fi, n, 9, 7)
        frames.append(compose(bg: plateAt(ox, oy), layers: [Layer(mask: ring[2], colour: { _, _ in idx(0x005555) }), Layer(mask: ring[1], colour: { _, _ in idx(0x00AAAA) }),
                                                    Layer(mask: ring[0], colour: { _, _ in idx(0xAAFFFF) }), Layer(mask: win, colour: winAt(winLit, ox, oy))])) }
    writeGIF(frames, prefix + "_night.gif", scale: 3, delay: 0.065)
    writePNG(unlit, prefix + "_nu_1x.png", scale: 1); writePNG(unlit, prefix + "_nu_4x.png", scale: 4)
    writePNG(frames[14], prefix + "_nl_1x.png", scale: 1); writePNG(frames[14], prefix + "_nl_4x.png", scale: 4)
    px = unlit
case "dayplate":   // args: weather
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    let tex = WX2[args[4]]?() ?? { let sp = WX[args[4]]!; return ditherRamp(sp.tex(), sp.ramp.map(idx), method: "atkinson", strength: 1) }()
    TW = W; TH = H
    let f = digitFont()
    let win = render((layoutRow(f, "10", top: 9, digitH: digitH, centreX: 100) + layoutRow(f, "48", top: 121, digitH: digitH, centreX: 100)).map { gpath(f, $0.g, $0.x, $0.baseline) })
    var first: [Int] = []
    for (name, base, glow, sx, sy) in SKY_TIMES {
        let plate = skyPlate(base: base, glow: glow, sunX: sx, sunY: sy)
        let fr = compose(bg: { hx, hy in plate[(hy / SS) * W + hx / SS] }, layers: [Layer(mask: win, colour: { hx, hy in tex[(hy / SS + M) * (W + 2 * M) + hx / SS + M] })])
        writePNG(fr, prefix + "_" + name + "_1x.png", scale: 1); writePNG(fr, prefix + "_" + name + "_4x.png", scale: 4)
        if first.isEmpty { first = fr }
    }
    px = first
case "dayplate2":   // args: weather ; stills for 4 times + one GIF cycling the times with tilt (plate moves at 0.35x)
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    let tex = WX2[args[4]]?() ?? { let sp = WX[args[4]]!; return ditherRamp(sp.tex(), sp.ramp.map(idx), method: "atkinson", strength: 1) }()
    let plates = SKY2.map { skyPlate2($0, margin: M, glow: args[4] != "sunny") }
    TW = W; TH = H
    let TWm = W + 2 * M
    let f = digitFont()
    let win = render((layoutRow(f, "10", top: 9, digitH: digitH, centreX: 100) + layoutRow(f, "48", top: 121, digitH: digitH, centreX: 100)).map { gpath(f, $0.g, $0.x, $0.baseline) })
    var frames: [[Int]] = []
    for (k, st) in SKY2.enumerated() {
        let pl = plates[k]
        let still = compose(bg: { hx, hy in pl[(hy / SS + M) * TWm + hx / SS + M] }, layers: [Layer(mask: win, colour: { hx, hy in tex[(hy / SS + M) * TWm + hx / SS + M] })])
        writePNG(still, prefix + "_" + st.name + "_1x.png", scale: 1); writePNG(still, prefix + "_" + st.name + "_4x.png", scale: 4)
        let n = 32
        for fi in 0..<n {
            let (ox, oy) = tilt(fi, n, 13, 9)
            let px2 = Int((Double(ox) * 0.35).rounded()), py2 = Int((Double(oy) * 0.35).rounded())
            frames.append(compose(bg: { hx, hy in pl[(hy / SS + M + py2) * TWm + hx / SS + M + px2] },
                                  layers: [Layer(mask: win, colour: { hx, hy in tex[(hy / SS + M + oy) * TWm + hx / SS + M + ox] })]))
        }
    }
    writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.065)
    px = frames[0]
case "dayplate3":   // args: weather times(comma)
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    let wname = args[4]
    let tex = WX2[wname]?() ?? { let sp = WX[wname]!; return ditherRamp(sp.tex(), sp.ramp.map(idx), method: "atkinson", strength: 1) }()
    let times = args[5].split(separator: ",").map(String.init)
    let plates = times.map { tn in skyPlate3(SKY2.first { $0.name == tn }!, ramp: skyRamp(tn, wname), margin: M, glow: wname != "sunny") }
    TW = W; TH = H
    let TWm = W + 2 * M
    let f = digitFont()
    let win = render((layoutRow(f, "10", top: 9, digitH: digitH, centreX: 100) + layoutRow(f, "48", top: 121, digitH: digitH, centreX: 100)).map { gpath(f, $0.g, $0.x, $0.baseline) })
    var frames: [[Int]] = [], lastStill: [Int] = []
    for (k, tn) in times.enumerated() {
        let pl = plates[k]
        let still = compose(bg: { hx, hy in pl[(hy / SS + M) * TWm + hx / SS + M] }, layers: [Layer(mask: win, colour: { hx, hy in tex[(hy / SS + M) * TWm + hx / SS + M] })])
        writePNG(still, prefix + "_" + tn + "_1x.png", scale: 1); writePNG(still, prefix + "_" + tn + "_4x.png", scale: 4)
        lastStill = still
        if ENV["GIF"] == "1" {
            for fi in 0..<32 {
                let (ox, oy) = tilt(fi, 32, 13, 9)
                let px2 = Int((Double(ox) * 0.35).rounded()), py2 = Int((Double(oy) * 0.35).rounded())
                frames.append(compose(bg: { hx, hy in pl[(hy / SS + M + py2) * TWm + hx / SS + M + px2] },
                                      layers: [Layer(mask: win, colour: { hx, hy in tex[(hy / SS + M + oy) * TWm + hx / SS + M + ox] })]))
            }
        }
    }
    if !frames.isEmpty { writeGIF(frames, prefix + ".gif", scale: 3, delay: 0.065) }
    px = frames.first ?? lastStill
case "export":   // args: outdir -> watch art as palette-index planes + manifest.json, packed by tools/pack.py
    let out = args[4]
    try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    var manifest: [String: Any] = [:]
    // .u8 = uint16 LE width, uint16 LE height, then one byte per pixel (Pebble colour index or glyph code)
    func writeU8(_ name: String, _ v: [Int], _ w: Int, _ h: Int) {
        var d = Data([UInt8(w & 255), UInt8(w >> 8), UInt8(h & 255), UInt8(h >> 8)])
        d.append(contentsOf: v.map { UInt8($0) })
        try! d.write(to: URL(fileURLWithPath: out + "/" + name + ".u8"))
    }
    // weather textures: the screen plus a 16 px tilt margin on every side
    let M = 16; TW = W + 2 * M; TH = H + 2 * M
    for name in ["sunny", "partly", "cloudy", "rain", "snow", "storm", "fog"] {
        let tex = WX2[name]?() ?? { let sp = WX[name]!; return ditherRamp(sp.tex(), sp.ramp.map(idx), method: "atkinson", strength: 1) }()
        writeU8("tex_" + name, tex, TW, TH)
        if let night = NIGHT_TEX[name] { writeU8("tex_" + name + "_night", night(), TW, TH) }
    }
    // moon: the whole disc (diameter MD) centred on a canvas with a 12 px margin, so the watch can cut
    // any placement window out of it
    let MDIAM = Double(ENV["MD"] ?? "300")!, MC = Int(MDIAM / 2) + 12
    TW = 2 * MC; TH = 2 * MC
    writeU8("moon", ditherRamp(moonTone(at: (Double(MC), Double(MC)), diameter: MDIAM), [0x000000, 0x555555, 0xAAAAAA].map(idx), method: "atkinson", strength: 1), TW, TH)
    manifest["moon"] = ["diameter": MDIAM, "centre": MC]
    TW = W; TH = H
    // digits: each glyph rendered once at its best 1/8 px phase, as a map of codes:
    //  15 inside, 14 edge at 2/3 cover, 13 edge at 1/3 cover, 1..12 outside at distance (k-1)/2..k/2 px, 0 beyond
    let f = digitFont(), sc = 1.0 / Double(SS), G = 7
    func glyphMask(_ g: CGGlyph, penX: Double, baseRow: Int, w: Int, h: Int) -> [UInt8] {
        let cw = w * SS, ch = h * SS
        let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.setFillColor(gray: 1, alpha: 1)
        var t = CGAffineTransform(translationX: CGFloat(penX * Double(SS)), y: CGFloat((h - baseRow) * SS))
        ctx.addPath(CTFontCreatePathForGlyph(f, g, &t)!); ctx.fillPath()
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: cw * ch)
        return Array(UnsafeBufferPointer(start: p, count: cw * ch))
    }
    func cover(_ m: [UInt8], _ w: Int, _ h: Int) -> [Double] {
        var c = [Double](repeating: 0, count: w * h)
        for y in 0..<(h * SS) { for x in 0..<(w * SS) { c[(y / SS) * w + x / SS] += Double(m[y * w * SS + x]) } }
        return c.map { $0 / Double(SS * SS * 255) }
    }
    // exact squared Euclidean distance transform (Felzenszwalb and Huttenlocher), in hi-res samples
    func edt(_ inside: [Bool], _ w: Int, _ h: Int) -> [Double] {
        let INF = 1e20
        func pass(_ fv: [Double]) -> [Double] {
            let n = fv.count; var d = [Double](repeating: 0, count: n), v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1)
            var k = 0; z[0] = -INF; z[1] = INF
            for q in 1..<n {
                var s = ((fv[q] + Double(q * q)) - (fv[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
                while s <= z[k] { k -= 1; s = ((fv[q] + Double(q * q)) - (fv[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k]) }
                k += 1; v[k] = q; z[k] = s; z[k + 1] = INF
            }
            k = 0
            for q in 0..<n { while z[k + 1] < Double(q) { k += 1 }; d[q] = Double((q - v[k]) * (q - v[k])) + fv[v[k]] }
            return d
        }
        var g = inside.map { $0 ? 0.0 : INF }
        for x in 0..<w { let col = pass((0..<h).map { g[$0 * w + x] }); for y in 0..<h { g[y * w + x] = col[y] } }
        for y in 0..<h { let row = pass(Array(g[(y * w)..<(y * w + w)])); for x in 0..<w { g[y * w + x] = row[x] } }
        return g
    }
    var glyphs: [[String: Any]] = [], fracs = [Double](repeating: 0, count: 10), lefts = [Int](repeating: 0, count: 10)
    var advs = [Double](), bbs = [CGRect]()
    for (d, ch) in "0123456789".enumerated() {
        let g = glyph(f, ch), bb = bbox(f, g)
        advs.append(Double(advance(f, g)) * sc); bbs.append(bb)
        let minX = Double(bb.minX) * sc, maxX = Double(bb.maxX) * sc, minY = Double(bb.minY) * sc, maxY = Double(bb.maxY) * sc
        // geometry for a pen at x = frac (bitmap x origin L is relative to the pen's whole-pixel position)
        func geom(_ frac: Double) -> (L: Int, w: Int, B: Int, h: Int) {
            let L = Int(floor(frac + minX)) - G, R = Int(ceil(frac + maxX)) + G
            let T = Int(floor(-maxY)) - G, Bt = Int(ceil(-minY)) + G
            return (L, R - L, -T, Bt - T)
        }
        var best = 0.0, bestCost = Double.infinity
        for k in 0..<SS {
            let frac = Double(k) / Double(SS), gm = geom(frac)
            let c = cover(glyphMask(g, penX: frac - Double(gm.L), baseRow: gm.B, w: gm.w, h: gm.h), gm.w, gm.h)
            let cost = c.reduce(0) { $0 + $1 * (1 - $1) }
            if cost < bestCost { bestCost = cost; best = frac }
        }
        let gm = geom(best)
        let m = glyphMask(g, penX: best - Double(gm.L), baseRow: gm.B, w: gm.w, h: gm.h)
        let c = cover(m, gm.w, gm.h)
        let hw = gm.w * SS, hh = gm.h * SS
        let d2 = edt(m.map { $0 >= 128 }, hw, hh)
        var codes = [Int](repeating: 0, count: gm.w * gm.h)
        for y in 0..<gm.h { for x in 0..<gm.w {
            let i = y * gm.w + x, cv = c[i]
            if cv >= 5.0 / 6 { codes[i] = 15 } else if cv >= 0.5 { codes[i] = 14 } else if cv >= 1.0 / 6 { codes[i] = 13 } else {
                // the pixel centre falls between four samples; average them, and measure to the ink edge,
                // half a sample short of the nearest inside sample's centre
                var acc = 0.0
                for (sy, sx) in [(SS / 2 - 1, SS / 2 - 1), (SS / 2 - 1, SS / 2), (SS / 2, SS / 2 - 1), (SS / 2, SS / 2)] {
                    acc += sqrt(d2[(y * SS + sy) * hw + x * SS + sx])
                }
                let dist = max(0, acc / 4 - 0.5) / Double(SS)
                let k = Int(dist / 0.5) + 1
                codes[i] = k <= 12 ? k : 0
            }
        } }
        writeU8("digit_\(d)", codes, gm.w, gm.h)
        fracs[d] = best; lefts[d] = gm.L
        glyphs.append(["digit": d, "frac": best, "left": gm.L, "baseline": gm.B, "w": gm.w, "h": gm.h, "partial_cost": bestCost])
    }
    manifest["glyphs"] = glyphs
    // layout (spec "Layout and digits"): ink extents of the pair centred on the screen, tracking -2% of cap
    // height; each digit then snaps to the whole pixel that keeps its hinted phase, within 0.5 px of the ideal
    let track = -0.02 * digitH, mid = Double(W) / 2
    var pairs: [[Int]] = [], singles: [Int] = []
    for a in 0..<10 { for b in 0..<10 {
        let left = Double(bbs[a].minX) * sc, right = advs[a] + track + Double(bbs[b].maxX) * sc
        let x0 = mid - (left + right) / 2, xs = [x0, x0 + advs[a] + track]
        pairs.append([Int((xs[0] - fracs[a]).rounded()) + lefts[a], Int((xs[1] - fracs[b]).rounded()) + lefts[b]])
    } }
    for a in 0..<10 {
        let x = mid - (Double(bbs[a].minX) + Double(bbs[a].maxX)) * sc / 2
        singles.append(Int((x - fracs[a]).rounded()) + lefts[a])
    }
    manifest["layout"] = ["pairs": pairs, "singles": singles, "baselines": ROW_TOP.map { Int($0) + Int(digitH) }]
    manifest["screen"] = [W, H]
    let js = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try! js.write(to: URL(fileURLWithPath: out + "/manifest.json"))
    print("exported to \(out)")
    px = [Int](repeating: 0, count: W * H)
default:
    px = compose(bg: moonSample, layers: [])
}
writePNG(px, prefix + "_1x.png", scale: 1)
writePNG(px, prefix + "_4x.png", scale: 4)
let used = Set(px).sorted().map { i -> String in let c = rgb(i); return String(format: "%02X%02X%02X", Int(c.0), Int(c.1), Int(c.2)) }
print("\(prefix): \(used.count) colours: \(used.joined(separator: " "))")
