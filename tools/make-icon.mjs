// Claudo's app icon as SVG: a ball of yarn wound from five session threads, two loose ends, the Claude spark in
// the corner. Usage: node tools/make-icon.mjs [light|dark] [out.svg] (tools/make-icon.sh renders it to PNG).
//
// Each thread is wound on a sphere as a slow helix (wraps side by side around a tilted axis, so a thread reads as a
// band of 2-3 parallel strands), seen in orthographic projection. Strands taper toward the silhouette and stop just
// inside it; the back of the ball is not drawn. Winding time sets the layer: a strand wound later lies on a slightly
// larger sphere, so wherever two strands meet the later one is on top, and over/under is plain 3D depth, consistent
// everywhere. Each under-strand gets a clean background gap where an over-strand crosses it, as a mask clipped to
// the under-strand's own band. A loose end peels off the silhouette and trails away (a 2D cubic), on top of all.
import fs from 'node:fs'

const LOGO = fs.readFileSync(new URL('./claude.svg', import.meta.url), 'utf8').match(/ d="([^"]+)"/)[1]
const variant = process.argv[2] ?? 'light'
const out = process.argv[3] ?? `${variant}.svg`

// ---------------------------------------------------------------- colors
const PALETTE = {
  blue: ['#2E7CF6', '#4F95FF'], teal: ['#00B3A4', '#20D3C2'], amber: ['#FFB000', '#FFC233'],
  violet: ['#8A5CF6', '#A88BFF'], rose: ['#F0508C', '#FF6FA4'],
}
const THEMES = {
  light: { bg: ['#FFFDFA', '#F0EBE3'], disc: ['#EFE8DE', '#E2D8CB'], spark: '#D97757', dark: 0 },
  dark: { bg: ['#2F2825', '#171311'], disc: ['#3D3531', '#2E2724'], spark: '#E58565', dark: 1 },
}
const T = THEMES[variant]
const color = name => PALETTE[name][T.dark]

// ---------------------------------------------------------------- composition
// Thread: axis = [azimuth°, elevation°] of the helix axis; the latitude creeps lat0 -> lat0 + dlat over `wraps`
// turns, starting at angle th0°. tail: the strand leaves the ball at fraction f of its last front run and trails
// to `to` along a cubic that leaves along the strand (control point `out` px ahead) and arrives along `in`.
const W = 42 // strand width
const GAP = 12 // background gap around an over-strand
const BALL = { c: [506, 546], r: 296, grow: 0.05 }
const SPARK = { at: [778, 246], size: 184 }
const THREADS = [
  { color: 'blue', axis: [145, 20], lat0: -10, dlat: 29, wraps: 2.12, th0: 35 },
  { color: 'violet', axis: [200, 49], lat0: -26, dlat: 32, wraps: 2.19, th0: 190 },
  { color: 'teal', axis: [292, 19], lat0: -33, dlat: 34, wraps: 2.5, th0: 242,
    tail: { f: 0.85, to: [858, 812], out: 90, in: [5, -70] } },
  { color: 'amber', axis: [376, -19], lat0: -34, dlat: 33, wraps: 2.38, th0: 354,
    tail: { f: 0.9, to: [170, 830], out: 140, in: [30, 55] } },
  { color: 'rose', axis: [442, 44], lat0: -33, dlat: 40, wraps: 2.54, th0: 110 },
]
const ZC = 0.2 // strands are seen where depth/r >= ZC: they end (tapered) just inside the silhouette
const MINBIT = 40 // shorter bits of a strand left between two gaps are hidden

// ---------------------------------------------------------------- vector maths
const sub = (a, b) => [a[0] - b[0], a[1] - b[1]], add = (a, b) => [a[0] + b[0], a[1] + b[1]]
const mul = (a, k) => [a[0] * k, a[1] * k], len = a => Math.hypot(a[0], a[1])
const rad = d => d * Math.PI / 180
const v3 = {
  add: (a, b) => a.map((v, i) => v + b[i]), mul: (a, k) => a.map(v => v * k),
  cross: (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]],
}
v3.norm = a => v3.mul(a, 1 / Math.hypot(...a))

// One thread wound on the sphere: samples {p (screen), z (depth, px), zr (depth / radius), w (width)}.
function wind(th) {
  const az = rad(th.axis[0]), el = rad(th.axis[1]) // screen y is down; azimuth ccw
  const ax = v3.norm([Math.cos(el) * Math.cos(az), -Math.cos(el) * Math.sin(az), Math.sin(el)])
  const a1 = v3.norm(v3.cross(ax, Math.abs(ax[2]) > 0.9 ? [1, 0, 0] : [0, 0, 1])), a2 = v3.cross(ax, a1)
  const at = (theta, s) => {
    const lat = rad(th.lat0 + th.dlat * s)
    return v3.add(v3.mul(v3.add(v3.mul(a1, Math.cos(theta)), v3.mul(a2, Math.sin(theta))), Math.cos(lat)),
      v3.mul(ax, Math.sin(lat)))
  }
  // winding time s: 0..1 over `wraps` turns, stretched so both ends sit on the back (a loose end needs no tail end)
  const thAt = s => rad(th.th0) + 2 * Math.PI * th.wraps * s
  const ds = 0.004 / (2 * Math.PI * th.wraps)
  let s0 = 0, s1 = 1
  if (!th.tail) { while (at(thAt(s1), s1)[2] > -0.05) s1 += ds }
  while (at(thAt(s0), s0)[2] > -0.05) s0 -= ds
  const N = Math.ceil((s1 - s0) / ds), pts = []
  for (let i = 0; i <= N; i++) {
    const s = s0 + (s1 - s0) * i / N, q = at(thAt(s), s)
    const r = BALL.r * (1 - BALL.grow + BALL.grow * s)
    const wf = Math.pow(Math.max(0, (Math.abs(q[2]) - ZC) / (1 - ZC)), 0.5) // taper with depth toward the limb
    pts.push({ p: [BALL.c[0] + r * q[0], BALL.c[1] - r * q[1]], z: r * q[2], zr: q[2], w: W * wf })
  }
  return pts
}

// The stretches on the front of the ball; the band around the limb and the back are not drawn.
function frontRuns(pts) {
  const out = []; let cur = null
  for (const q of pts) {
    if (q.zr < ZC) { cur = null; continue }
    if (!cur) { cur = { pts: [] }; out.push(cur) }
    cur.pts.push(q)
  }
  return out
}
function resample(pts, step = 3) { // even spacing along screen arc length, interpolating z and w
  const out = [pts[0]]; let carry = 0
  for (let i = 1; i < pts.length; i++) {
    const a = pts[i - 1], b = pts[i], l = len(sub(b.p, a.p)); let t = step - carry
    while (t <= l) {
      const k = t / l
      out.push({ p: add(a.p, mul(sub(b.p, a.p), k)), z: a.z + (b.z - a.z) * k, w: a.w + (b.w - a.w) * k })
      t += step
    }
    carry = l - (t - step)
  }
  if (len(sub(out.at(-1).p, pts.at(-1).p)) > 0.5) out.push(pts.at(-1))
  return out
}
function bez(P0, P1, P2, P3, n = 200) {
  const o = []
  for (let i = 0; i <= n; i++) {
    const t = i / n, u = 1 - t
    o.push(add(add(mul(P0, u * u * u), mul(P1, 3 * u * u * t)), add(mul(P2, 3 * u * t * t), mul(P3, t * t * t))))
  }
  return o
}

const pieces = [] // {color, pts: [{p, z, w}], capB}
for (const th of THREADS) {
  const rs = frontRuns(wind(th))
  if (th.tail) { // leave the ball partway along the last front run: a loose end hanging out
    const run = rs.at(-1), cut = Math.max(2, Math.round(run.pts.length * th.tail.f))
    run.pts = run.pts.slice(0, cut)
    // the peeling strand keeps its full width out to the edge (it lies on top, about to lift off)
    let im = 0; run.pts.forEach((q, n) => { if (q.w > run.pts[im].w) im = n })
    for (let n = im; n < run.pts.length; n++) run.pts[n] = { ...run.pts[n], w: Math.max(run.pts[n].w, run.pts[im].w) }
    // the last stretch before it lifts off lies on top of everything
    for (let n = Math.floor(run.pts.length * 0.75); n < run.pts.length; n++) {
      run.pts[n] = { ...run.pts[n], z: Math.max(run.pts[n].z, BALL.r * 2) }
    }
    const e = run.pts.at(-1), d = sub(e.p, run.pts.at(-4).p), dir = mul(d, 1 / len(d)), tail = th.tail
    const curve = bez(e.p, add(e.p, mul(dir, tail.out)), add(tail.to, tail.in), tail.to).slice(1)
    const zTop = BALL.r * 2, ramp = 30
    curve.forEach((p, i) => run.pts.push({
      p, z: e.z + (zTop - e.z) * Math.min(1, (i + 1) / ramp), w: e.w + (W - e.w) * Math.min(1, (i + 1) / ramp),
    }))
    run.capB = true
  }
  for (const r of rs) {
    if (r.pts.length < 3) continue
    let L = 0; for (let n = 1; n < r.pts.length; n++) L += len(sub(r.pts[n].p, r.pts[n - 1].p))
    if (L < 40 || Math.max(...r.pts.map(q => q.w)) < W * 0.3) continue // a speck at the limb, not a strand
    pieces.push({ color: th.color, pts: resample(r.pts), capB: r.capB })
  }
}
const meanZ = pc => pc.pts.reduce((s, q) => s + q.z, 0) / pc.pts.length
pieces.sort((a, b) => meanZ(a) - meanZ(b)) // back to front
const lines = pieces.map(pc => pc.pts.map(q => q.p))

// ---------------------------------------------------------------- crossings (screen space), over/under by depth
function segX(a, b, c, d) {
  const r = sub(b, a), s = sub(d, c), den = r[0] * s[1] - r[1] * s[0]
  if (Math.abs(den) < 1e-9) return null
  const q = sub(c, a), t = (q[0] * s[1] - q[1] * s[0]) / den, u = (q[0] * r[1] - q[1] * r[0]) / den
  return t >= 0 && t < 1 && u >= 0 && u < 1 ? t : null
}
const crossings = [] // {i, j: pieces; a, b: where along each; ang: angle°; at: point; top: the piece on top}
for (let i = 0; i < lines.length; i++) for (let j = i + 1; j < lines.length; j++) {
  const A = lines[i], B = lines[j]
  for (let a = 0; a < A.length - 1; a++) for (let b = 0; b < B.length - 1; b++) {
    if (Math.abs(A[a][0] - B[b][0]) > 8 || Math.abs(A[a][1] - B[b][1]) > 8) continue
    const h = segX(A[a], A[a + 1], B[b], B[b + 1]); if (h === null) continue
    const hb = segX(B[b], B[b + 1], A[a], A[a + 1])
    const da = sub(A[a + 1], A[a]), db = sub(B[b + 1], B[b])
    const ang = Math.acos(Math.min(1, Math.abs((da[0] * db[0] + da[1] * db[1]) / (len(da) * len(db))))) * 180 / Math.PI
    const zi = pieces[i].pts[a].z + (pieces[i].pts[a + 1].z - pieces[i].pts[a].z) * h
    const zj = pieces[j].pts[b].z + (pieces[j].pts[b + 1].z - pieces[j].pts[b].z) * hb
    crossings.push({ i, j, a: a + h, b: b + hb, ang, at: add(A[a], mul(da, h)), top: zi >= zj ? i : j })
  }
}

// ---------------------------------------------------------------- drawing
const f1 = n => n.toFixed(1)
const D = pts => 'M' + pts.map(p => f1(p[0]) + ' ' + f1(p[1])).join('L')
function stretch(pc, at, c, R) { // the points of a piece around index `at` that stay within R of c
  const L = pc.pts; let lo = Math.floor(at), hi = Math.ceil(at)
  while (lo > 0 && len(sub(L[lo - 1].p, c)) < R) lo--
  while (hi < L.length - 1 && len(sub(L[hi + 1].p, c)) < R) hi++
  return L.slice(lo, hi + 1)
}
function band(pts, extra = 0, k = 0.5) { // outline polygon of a stretch with its own (variable) width
  const Lf = [], Rt = []
  pts.forEach((q, n) => {
    const a = pts[Math.max(0, n - 1)].p, b = pts[Math.min(pts.length - 1, n + 1)].p, d = sub(b, a), l = len(d) || 1
    const h = q.w * k + extra, nn = [-d[1] / l * h, d[0] / l * h]
    Lf.push(add(q.p, nn)); Rt.push(sub(q.p, nn))
  })
  return D([...Lf, ...Rt.reverse()]) + 'Z'
}
const shape = pc => { // the strand itself: variable-width outline plus a round cap at a loose end
  let d = band(pc.pts)
  const cap = q => {
    const r = q.w / 2
    const arc = dx => `a${f1(r)} ${f1(r)} 0 1 0 ${f1(dx)} 0`
    return `M${f1(q.p[0] - r)} ${f1(q.p[1])}${arc(2 * r)}${arc(-2 * r)}Z`
  }
  if (pc.capB) d += cap(pc.pts.at(-1))
  return d
}
// The gaps cut into piece t where another piece crosses over it: the over-strand's band widened by GAP, clipped to
// the under-strand's band near the crossing.
const cutsFor = t => crossings.map((x, k) => {
  if (x.i !== t && x.j !== t) return null
  if (x.top === t) return null
  const top = x.top, topAt = top === x.i ? x.a : x.b, underAt = top === x.i ? x.b : x.a
  const th = rad(Math.max(x.ang, 12))
  const wt = pieces[top].pts[Math.round(topAt)].w, wu = pieces[t].pts[Math.round(underAt)].w
  const R = (wt / 2 + GAP) / Math.sin(th) + (wu / 2) / Math.tan(th) + 6
  const topRun = stretch(pieces[top], topAt, x.at, R + wu + GAP)
  return { k, topRun, clip: band(stretch(pieces[t], underAt, x.at, R), 2), d: band(topRun, GAP) }
}).filter(Boolean)
// Crumbs: bits of a strand left between two close gaps, or a thin end cut off by a gap, read as noise. Find the
// stretches of center line not covered by any gap and hide those that are too short or too thin.
function crumbs(pc, cuts) {
  // a point counts as cut when most of the strand's width there is under some halo (catches thin edge slivers too)
  const inHalo = p => cuts.some(c => c.topRun.some(u => len(sub(u.p, p)) < u.w / 2 + GAP + 1))
  const cut = [], cov = pc.pts.map((q, n) => {
    const a = pc.pts[Math.max(0, n - 1)].p, b = pc.pts[Math.min(pc.pts.length - 1, n + 1)].p, d = sub(b, a)
    const l = len(d) || 1, nn = [-d[1] / l, d[0] / l]
    const offs = [-0.45, -0.22, 0, 0.22, 0.45].map(f => add(q.p, mul(nn, f * q.w)))
    return offs.filter(inHalo).length
  })
  const out = []; let a = -1
  // long stretches that are mostly but not fully covered: a thin edge sliver left between halos, hide it whole
  for (let n = 0, s0 = -1; n <= cov.length; n++) {
    const sl = n < cov.length && cov[n] >= 3 && cov[n] < 5
    if (sl && s0 < 0) s0 = n
    if (!sl && s0 >= 0) {
      if (n - s0 >= 8) out.push(pc.pts.slice(Math.max(0, s0 - 2), Math.min(pc.pts.length, n + 2)))
      s0 = -1
    }
  }
  cov.forEach((c, n) => { cut[n] = c >= 3 })
  // fully covered across the width: hide it edge to edge, so no hairline of the strand's rim survives between halos
  for (let n = 0, s0 = -1; n <= cov.length; n++) {
    const full = n < cov.length && cov[n] === 5
    if (full && s0 < 0) s0 = n
    if (!full && s0 >= 0) { if (n - s0 >= 3) out.push(pc.pts.slice(s0, n)); s0 = -1 }
  }
  for (let n = 0; n <= pc.pts.length; n++) {
    if (n < pc.pts.length && !cut[n]) { if (a < 0) a = n; continue }
    if (a >= 0) {
      const seg = pc.pts.slice(a, n)
      let L = 0; for (let i = 1; i < seg.length; i++) L += len(sub(seg[i].p, seg[i - 1].p))
      const wmax = Math.max(...seg.map(q => q.w))
      if (L < MINBIT || wmax < W * 0.3) out.push(pc.pts.slice(Math.max(0, a - 8), Math.min(pc.pts.length, n + 8)))
      a = -1
    }
  }
  return out
}

// the ball's body: flat, a touch lighter toward the upper left
let defs = `<radialGradient id="disc" gradientUnits="userSpaceOnUse" cx="${BALL.c[0] - BALL.r * 0.3}" `
  + `cy="${BALL.c[1] - BALL.r * 0.35}" r="${BALL.r * 1.45}"><stop offset="0" stop-color="${T.disc[0]}"/>`
  + `<stop offset="1" stop-color="${T.disc[1]}"/></radialGradient>`
let body = `<circle cx="${BALL.c[0]}" cy="${BALL.c[1]}" r="${BALL.r}" fill="url(#disc)"/>`
pieces.forEach((pc, t) => {
  const cuts = cutsFor(t)
  if (cuts.length) {
    defs += `<mask id="m${t}" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">`
      + '<rect width="1024" height="1024" fill="#fff"/>'
    for (const c of cuts) {
      const id = `m${t}c${c.k}`
      defs += `<clipPath id="${id}"><path d="${c.clip}"/></clipPath><path clip-path="url(#${id})" d="${c.d}" fill="#000"/>`
    }
    for (const bit of crumbs(pc, cuts)) defs += `<path d="${band(bit, 6)}" fill="#000"/>`
    defs += '</mask>'
  }
  body += `<path d="${shape(pc)}" ${cuts.length ? `mask="url(#m${t})"` : ''} fill="${color(pc.color)}"/>`
})
const sc = SPARK.size / 100
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="0" y1="100" x2="0" y2="924"><stop offset="0" stop-color="${T.bg[0]}"/><stop offset="1" stop-color="${T.bg[1]}"/></linearGradient>
  <filter id="drop" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/><feComponentTransfer><feFuncA type="linear" slope="0.3"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  ${defs}
  <clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)" filter="url(#drop)"/>
<g clip-path="url(#sq)">
  ${body}
  <path d="${LOGO}" transform="translate(${SPARK.at[0] - SPARK.size / 2} ${SPARK.at[1] - SPARK.size / 2}) scale(${sc})" fill="${T.spark}"/>
</g>
</svg>`
fs.writeFileSync(out, svg)
