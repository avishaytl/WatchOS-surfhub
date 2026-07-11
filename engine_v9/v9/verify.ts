// verify.ts — equivalence + regression smoke test for the review edits.
import type { SensorSample } from './types.ts';
import { detectJumps, DEFAULT_JUMP_PARAMS, baroAltitudeSeries, type JumpEngineParams, type JumpResult } from './jumpEngine.ts';
import { replayScan, JumpScannerV9, DEFAULT_SCAN_CONFIG } from './jumpScanV9.ts';

// ── deterministic RNG ──
let seed = 42;
const rnd = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
const gauss = (s = 1) => s * (rnd() + rnd() + rnd() + rnd() - 2) / 0.577;

// ── synthetic kite session: 50 Hz IMU, ~0.35 Hz baro, 1 Hz GPS speed ──
function makeSession(
  durSec: number, jumps: { t: number; h: number }[], baroGapMs = 2800,
  drift?: { t0: number; hpa: number; riseSec: number }, // linear pressure DROP of `hpa` over riseSec, then held
): SensorSample[] {
  const out: SensorSample[] = [];
  const dt = 20; // ms
  let baroT = 0, lastBaro = 1013.25;
  for (let t = 0; t < durSec * 1000; t += dt) {
    let alt = 0;
    for (const j of jumps) {
      const airtime = 2.63 * 2 * Math.sqrt((2 * j.h) / 9.81) * 1000;
      const x = (t - j.t * 1000) / airtime;
      if (x >= 0 && x <= 1) alt = Math.max(alt, 4 * j.h * x * (1 - x));
    }
    const inAir = alt > 0.2;
    const s: SensorSample = {
      t,
      ax: gauss(inAir ? 0.05 : 0.25), ay: gauss(inAir ? 0.05 : 0.25),
      az: gauss(inAir ? 0.05 : 0.25) + (inAir ? 0.2 : 0),
      gvX: 0, gvY: 0, gvZ: -1,
      gx: gauss(0.5), gy: gauss(0.5), gz: gauss(0.5),
      spd: 7 + gauss(0.5),
    };
    if (t - baroT >= baroGapMs) { // sparse baro
      baroT = t;
      let dp = 0;
      if (drift && t / 1000 >= drift.t0) dp = Math.min(drift.hpa, ((t / 1000 - drift.t0) / drift.riseSec) * drift.hpa);
      lastBaro = 1013.25 - dp - alt / 8.43 + gauss(0.01);
      s.baro = lastBaro;
    }
    out.push(s);
  }
  return out;
}

// ── legacy O(U²) baseline (verbatim pre-edit logic) for equivalence check ──
function legacyBaseline(s: SensorSample[], params: JumpEngineParams): number[] {
  const n = s.length;
  const raw = new Array<number>(n);
  let last = s.find((x) => x.baro != null)?.baro ?? 1013.25;
  for (let i = 0; i < n; i++) { if (s[i]!.baro != null) last = s[i]!.baro!; raw[i] = last; }
  // (despike off in this synthetic — thresholds never trip; compare baseline math only)
  const upIdx: number[] = []; const upVal: number[] = [];
  for (let i = 0; i < n; i++) if (!upVal.length || raw[i] !== upVal[upVal.length - 1]) { upIdx.push(i); upVal.push(raw[i]!); }
  const pastW = params.baselineHalfWinSec * 1000, futW = params.baselineFutureWinSec * 1000;
  const baseUp = upVal.map((_, k) => {
    const tk = s[upIdx[k]!]!.t;
    const wv: number[] = [];
    for (let j = 0; j < upVal.length; j++) {
      const d = s[upIdx[j]!]!.t - tk;
      if (d >= -pastW && d <= futW) wv.push(upVal[j]!);
    }
    const sorted = [...wv].sort((a, b) => a - b);
    const hi = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * params.baselinePctile))]!;
    const med = sorted[Math.min(sorted.length - 1, sorted.length >> 1)]!;
    return params.baselineMaxOffsetHpa <= 0 ? hi : med + Math.min(hi - med, params.baselineMaxOffsetHpa);
  });
  // garbage clamp (legacy full scan)
  if (params.baselineGarbageHpa > 0) {
    const driftW = params.baselineDriftWinSec * 1000;
    for (let k = 0; k < baseUp.length; k++) {
      const tk = s[upIdx[k]!]!.t;
      const wv: number[] = [];
      for (let j = 0; j < upVal.length; j++) { const d = s[upIdx[j]!]!.t - tk; if (d >= -driftW && d <= driftW) wv.push(upVal[j]!); }
      wv.sort((a, b) => a - b);
      const slowRef = wv[Math.min(wv.length - 1, Math.floor(wv.length * 0.2))]!;
      const cap = slowRef + params.baselineGarbageHpa;
      if (baseUp[k]! > cap) baseUp[k] = cap;
    }
  }
  const base = new Array<number>(n);
  let k = 0;
  for (let i = 0; i < n; i++) { while (k + 1 < upIdx.length && upIdx[k + 1]! <= i) k++; base[i] = baseUp[k] ?? upVal[k] ?? raw[i]!; }
  return raw.map((b, i) => (base[i]! - b) * 8.43);
}

let fails = 0;
const check = (name: string, ok: boolean, detail = '') => {
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ' — ' + detail : ''}`);
  if (!ok) fails++;
};

// TEST 1 — two-pointer baseline ≡ legacy O(U²) baseline, bit-for-bit
{
  const s = makeSession(600, [{ t: 100, h: 3.4 }, { t: 220, h: 2.1 }, { t: 400, h: 5.0 }]);
  const p = { ...DEFAULT_JUMP_PARAMS, baroDespikeWinSec: 0 }; // isolate the baseline math
  const a = baroAltitudeSeries(s, p);
  const b = legacyBaseline(s, p);
  let maxD = 0; for (let i = 0; i < a.length; i++) maxD = Math.max(maxD, Math.abs(a[i]! - b[i]!));
  check('baseline two-pointer ≡ legacy O(U²)', maxD < 1e-12, `maxΔ=${maxD.toExponential(2)}`);
}

// TEST 2 — detection: 3/3 at the real 0.36 Hz rate; ACCURACY checked at 1 Hz baro
// (the doc: height accuracy is baro-rate-bound; 0.36 Hz sub-samples a ~4 s arc).
{
  const s = makeSession(600, [{ t: 100, h: 3.4 }, { t: 220, h: 2.1 }, { t: 400, h: 5.0 }]);
  const r = detectJumps(s, DEFAULT_JUMP_PARAMS);
  check('detects 3/3 at 0.36 Hz baro', r.length === 3, `got ${r.length}: [${r.map((x) => x.jumpHeightM).join(', ')}] m`);
  const s1 = makeSession(600, [{ t: 100, h: 3.4 }, { t: 220, h: 2.1 }, { t: 400, h: 5.0 }], 1000);
  const r1 = detectJumps(s1, DEFAULT_JUMP_PARAMS);
  const errs = r1.map((x, i) => Math.abs(x.jumpHeightM - [3.4, 2.1, 5.0][i]!));
  check('1 Hz baro: 3/3 within 0.6 m', r1.length === 3 && errs.every((e) => e < 0.6), `errs=[${errs.map((e) => e.toFixed(2)).join(', ')}]`);
}

// TEST 3 — sep-conflict deferred pop: taller candidate FAILS run-up gate → the
// previously-accepted jump must SURVIVE (the eager pop lost both).
{
  const s = makeSession(200, [{ t: 60, h: 2.5 }]);
  // graft a taller apex 3 s later whose run-up speed is BELOW the planing gate
  const airtime = 2.63 * 2 * Math.sqrt((2 * 4.0) / 9.81) * 1000;
  for (const x of s) {
    const xr = (x.t - 63_000) / airtime;
    if (xr >= 0 && xr <= 1) {
      if (x.baro != null) x.baro = Math.min(x.baro, 1013.25 - (4 * 4.0 * xr * (1 - xr)) / 8.43);
      x.spd = 1.0; // standing — the taller candidate must fail the run-up gate
    }
  }
  const r = detectJumps(s, DEFAULT_JUMP_PARAMS);
  check('sep-conflict fix keeps the accepted jump', r.length >= 1, `got ${r.length} jump(s): [${r.map((x) => x.jumpHeightM).join(', ')}]`);
}

// TEST 4 — V9 replay: provisional precedes final with the same id; finals == whole-log
{
  const s = makeSession(600, [{ t: 100, h: 3.4 }, { t: 220, h: 2.1 }, { t: 400, h: 5.0 }]);
  const whole = detectJumps(s, DEFAULT_JUMP_PARAMS);
  const rep = replayScan(s, DEFAULT_JUMP_PARAMS, DEFAULT_SCAN_CONFIG);
  check('V9 finals == whole-log count', rep.finals.length === whole.length, `V9=${rep.finals.length} whole=${whole.length}`);
  const byId = new Map<number, string[]>();
  for (const e of rep.emissions) { const a = byId.get(e.id) ?? []; a.push(e.stage); byId.set(e.id, a); }
  const ordered = [...byId.values()].every((a) => a.join(',') === 'provisional,final');
  check('each id: provisional → final (in order)', ordered);
  const latOk = rep.finals.every((e) => e.viaFlush || e.emitLatencySec >= DEFAULT_SCAN_CONFIG.settleSec);
  check('finals respect settleSec ripeness', latOk);
}

// TEST 5 — constructor invariant warnings fire on a broken config
{
  let warned = 0; const orig = console.warn; console.warn = () => { warned++; };
  new JumpScannerV9(DEFAULT_JUMP_PARAMS, { ...DEFAULT_SCAN_CONFIG, windowSec: 30, settleSec: 5 });
  console.warn = orig;
  check('invariant warnings fire (window/settle too small)', warned >= 2, `${warned} warnings`);
}

// TEST 6 — empty-gap no-op + memory cap
{
  const sc = new JumpScannerV9(DEFAULT_JUMP_PARAMS, { ...DEFAULT_SCAN_CONFIG, maxBufferedSamples: 100 });
  for (let i = 0; i < 500; i++) sc.addSample({ t: i * 20, ax: 0, ay: 0, az: 0 } as SensorSample);
  check('memory cap enforced', sc.bufferedSamples <= 100, `buffered=${sc.bufferedSamples}`);
  const e = sc.scan(1e9); // far-future tick → window empty after eviction
  const e2 = sc.scan(1e9 + 2000); // no-op path
  check('empty-gap ticks are clean no-ops', e.length === 0 && e2.length === 0);
}


// TEST 7 — DRIFT GATE (the synthetic LOG2 #8): a fast pressure drift under a jump
// must FAIL the cleanNoDrift proof; a later jump on stable pressure must PASS.
{
  const s = makeSession(600, [{ t: 100, h: 2.5 }, { t: 300, h: 3.0 }], 2800,
    { t0: 95, hpa: 0.5, riseSec: 12 }); // ~LOG2 #8: 0.51 hPa over 12 s
  const r = detectJumps(s, DEFAULT_JUMP_PARAMS);
  const j1 = r.find((x) => Math.abs((x.takeoffTimeMs ?? 0) - 100_000) < 8000);
  const j2 = r.find((x) => Math.abs((x.takeoffTimeMs ?? 0) - 300_000) < 8000);
  check('drift jump detected (never dropped)', !!j1, j1 ? `h=${j1.jumpHeightM}m (true 2.5)` : 'missing');
  check('drift jump FAILS cleanNoDrift', !!j1 && j1.cleanNoDrift === false,
    j1 ? `rtz=${j1.returnToZeroHpa} slope=${j1.pastDriftSlopeHpaS} timedOut=${j1.landingTimedOut}` : '');
  check('clean jump PASSES cleanNoDrift', !!j2 && j2.cleanNoDrift === true,
    j2 ? `rtz=${j2.returnToZeroHpa} slope=${j2.pastDriftSlopeHpaS} q=${j2.specForceQuieting}` : '');
}

// TEST 8 — EARLY-FINALIZE routing: clean jumps get a ≤~6 s early FINAL; the drift
// jump keeps the safe settle path. Default config stays fully legacy (no earlies).
{
  const s = makeSession(600, [{ t: 100, h: 2.5 }, { t: 300, h: 3.0 }], 2800,
    { t0: 95, hpa: 0.5, riseSec: 12 });
  const whole = detectJumps(s, DEFAULT_JUMP_PARAMS);
  const repDef = replayScan(s, DEFAULT_JUMP_PARAMS, DEFAULT_SCAN_CONFIG);
  check('default config: zero early finals (legacy)', repDef.finals.every((e) => !e.early));
  const rep = replayScan(s, DEFAULT_JUMP_PARAMS, { ...DEFAULT_SCAN_CONFIG, earlyFinalizeSec: 4 });
  const near = (e: { jump: JumpResult }, t: number) => Math.abs((e.jump.takeoffTimeMs ?? 0) - t) < 8000;
  const f1 = rep.finals.find((e) => near(e, 100_000));
  const f2 = rep.finals.find((e) => near(e, 300_000));
  check('clean jump finalizes EARLY (≤7 s)', !!f2 && f2.early && f2.emitLatencySec <= 7,
    f2 ? `latency=${f2.emitLatencySec}s early=${f2.early}` : 'missing');
  check('drift jump keeps the SETTLE path', !!f1 && !f1.early && (f1.viaFlush || f1.emitLatencySec >= DEFAULT_SCAN_CONFIG.settleSec),
    f1 ? `latency=${f1.emitLatencySec}s early=${f1.early}` : 'missing');
  const wj2 = whole.find((x) => Math.abs((x.takeoffTimeMs ?? 0) - 300_000) < 8000);
  check('early final ≈ whole-log height', !!f2 && !!wj2 && Math.abs(f2.jump.jumpHeightM - wj2.jumpHeightM) < 0.35,
    f2 && wj2 ? `early=${f2.jump.jumpHeightM} whole=${wj2.jumpHeightM}` : '');
}

// TEST 9 — ½ΔB ENDPOINT CORRECTION, isolated at 1 Hz baro. At 0.36 Hz the
// sub-sampling UNDER-read entangles with (and accidentally cancels) the drift
// inflation — the documented reason corrections strip clean jumps — so the
// corrector is validated where the drift effect is isolated. Product rule: enable
// endpointDriftMaxHpa only with ≥1 Hz baro or after golden validation at 0.34 Hz.
{
  const mk = () => makeSession(600, [{ t: 100, h: 2.5 }, { t: 300, h: 3.0 }], 1000,
    { t0: 80, hpa: 0.12, riseSec: 30 }); // slow: baseline partially tracks, rtz measurable
  seed = 42; const sA = mk();
  seed = 42; const sB = mk();
  const off = detectJumps(sA, DEFAULT_JUMP_PARAMS);
  const on = detectJumps(sB, { ...DEFAULT_JUMP_PARAMS, endpointDriftMaxHpa: 0.6 });
  const pick = (r: JumpResult[], t: number) => r.find((x) => Math.abs((x.takeoffTimeMs ?? 0) - t) < 8000);
  const o1 = pick(off, 100_000), n1 = pick(on, 100_000);
  const o2 = pick(off, 300_000), n2 = pick(on, 300_000);
  const eOff = o1 ? Math.abs(o1.jumpHeightM - 2.5) : NaN;
  const eOn = n1 ? Math.abs(n1.jumpHeightM - 2.5) : NaN;
  check('ΔB correction: no worse on the drift jump', !!o1 && !!n1 && eOn <= eOff + 0.05,
    `err off=${eOff.toFixed(2)} on=${eOn.toFixed(2)} corr=${n1?.endpointDriftCorrM}`);
  check('ΔB correction: clean jump untouched (deadband)', !!o2 && !!n2 && Math.abs(n2.jumpHeightM - o2.jumpHeightM) <= 0.15,
    `off=${o2?.jumpHeightM} on=${n2?.jumpHeightM} corr=${n2?.endpointDriftCorrM}`);
}

console.log(fails === 0 ? '\nALL PASS' : `\n${fails} FAILURES`);
if (fails > 0) throw new Error(`${fails} verification failures`);
