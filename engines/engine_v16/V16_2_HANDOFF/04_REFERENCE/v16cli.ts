/**
 * v16cli — the V16.2 verification CLI.
 *
 *   npx tsx core/tools/v16cli.ts                 run the full reference suite
 *   npx tsx core/tools/v16cli.ts <log.kslog>     analyse a single log
 *   npx tsx core/tools/v16cli.ts --json          machine-readable suite output
 *
 * The suite scores every reference session the engine is validated against and
 * prints recall, phantoms, the TALLEST phantom (the metric that actually gates a
 * release) and the height / airtime / distance errors. It exits non-zero if any
 * guard-rail regresses, so it can be wired straight into CI.
 */
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { decodeKslog2 } from '../kslog2.ts';
import { log5FromStreams } from '../v12Analysis.ts';
import { analyseSessionV16 } from '../v16Analysis.ts';
import { V16_VERSION, type V16Config } from '../jumpEngineV16.ts';

type Golden = [t: number, h: number, air?: number | null, dist?: number | null];
interface Session { tag: string; path: string; gold: Golden[]; note: string }

const DL = join(homedir(), 'Downloads');
const RES = join(homedir(), 'Projects', 'SurfHub', 'research');

/** Reference suite. A missing log is SKIPPED, not failed — the set is personal. */
const SUITE: Session[] = [
  { tag: 'BENCH', note: '4 hand throws, ballistic truth g*T^2/8',
    path: join(RES, 'bench', 'log_20260804_111207_EC018703.kslog'),
    gold: [[24.5, 2.47], [42.9, 1.54], [63.6, 2.98], [80.9, 0.91]] },
  { tag: 'SMALL', note: '16 HOOLAN goldens, 1.5-3.7 m',
    path: join(RES, 'smallLog', 'log_20260729_145730_82AA910A.kslog'),
    gold: [[465,1.7,3.0,10.0],[555,2.9,3.8,17.4],[585,1.5,3.1],[621,3.1,3.5,17.4],[639,2.9,5.3,30.4],
           [661,2.8,3.4],[713,1.9,3.0,13.2],[737,2.1,3.5,20.7],[860,3.0,3.8,15.5],[892,3.7,4.0,19.9],
           [987,1.6,2.9,18.2],[1029,2.6,3.5,20.1],[1100,2.1,3.7,14.5],[1122,2.7,4.9,28.6],
           [1161,2.6,3.9,21.2],[1479,2.4,3.4,13.6]] },
  { tag: '287',   note: '14 HOOLAN goldens, big air 2.1-8.5 m',
    path: join(DL, 'log_287_20260728_182822_05D47F19.kslog'),
    gold: [[282,2.3,3.4,21.5],[324,5.4,4.6,27.1],[349,4.1,4.0,27.3],[429,8.5,5.6,35.8],[454,3.1,4.0,9.9],
           [526,4.1,4.5,28.9],[624,2.1,3.3,15.5],[652,6.0,5.4,24.4],[752,7.3,5.8,42.0],[779,8.4,5.9,28.5],
           [894,4.9,5.1,14.7],[1006,6.3,5.4,34.3],[1181,4.7,4.5,10.3],[1329,7.4,5.6,33.1]] },
  { tag: 'NEG',   note: 'CONTROL — pops and waves, zero real jumps',
    path: join(DL, 'log_neg_20260729_181501_5FD2D480.kslog'), gold: [] },
  { tag: 'CLEAN', note: '4 goldens, small jumps',
    path: join(DL, 'log_clean_20260717_141359_9F4B59A0.kslog'),
    gold: [[795,1.82],[812,1.67],[838,2.48],[1025,1.67]] },
  { tag: 'V142',  note: '5 goldens, small jumps',
    path: join(DL, 'logV142_20260720_142336_9B061DC9.kslog'),
    gold: [[403,1.55],[846,1.26],[1724,1.33],[1735,1.92],[2025,2.12]] },
];

/** Release guard-rails. Breaking one exits non-zero. */
const GUARDS = {
  negPhantoms: 0,        // the control session must stay silent
  tallestPhantomM: 2.6,  // a TALL phantom is the one failure a rider will not forgive
  minRecall: 34,         // of 39 riding goldens
  maxHeightMAE: 0.35,    // pooled over all riding goldens
};

const RULE = '-'.repeat(74);

function score(s: Session, cfg: Partial<V16Config> = {}) {
  const raw = decodeKslog2(new Uint8Array(readFileSync(s.path)));
  const em = analyseSessionV16(log5FromStreams(raw), cfg).v16.emissions.map(e => e.jump);
  const pairs: { d: number; ri: number; ji: number }[] = [];
  s.gold.forEach((g, ri) => em.forEach((j, ji) => {
    const d = Math.abs(j.takeoffT - g[0]); if (d < 8) pairs.push({ d, ri, ji });
  }));
  pairs.sort((a, b) => a.d - b.d);
  const mr = new Map<number, number>(), mj = new Set<number>();
  for (const p of pairs) { if (mr.has(p.ri) || mj.has(p.ji)) continue; mr.set(p.ri, p.ji); mj.add(p.ji) }
  const ph = em.filter((_, i) => !mj.has(i));
  const dh: number[] = [], da: number[] = [], dd: number[] = [];
  s.gold.forEach((g, ri) => {
    const i = mr.get(ri); if (i == null) return; const j = em[i]!;
    dh.push(j.heightM - g[1]);
    if (g[2] != null && j.airtimeSec != null) da.push(j.airtimeSec - g[2]);
    if (g[3] != null && j.distanceM != null) dd.push(j.distanceM - g[3]);
  });
  const mae = (A: number[]) => A.length ? A.reduce((x, y) => x + Math.abs(y), 0) / A.length : NaN;
  return { tag: s.tag, note: s.note, emitted: em.length, recall: mr.size, goldens: s.gold.length,
           phantoms: ph.length, tallest: ph.length ? Math.max(...ph.map(j => j.heightM)) : 0,
           heightMAE: mae(dh), airtimeMAE: mae(da), distMAE: mae(dd), dh };
}

function suite(json: boolean): number {
  const rows = [] as ReturnType<typeof score>[];
  const missing: string[] = [];
  for (const s of SUITE) {
    if (!existsSync(s.path)) { missing.push(s.tag); continue }
    rows.push(score(s));
  }
  if (json) { console.log(JSON.stringify({ version: V16_VERSION, rows }, null, 2)); return 0 }

  console.log(`\nV16 reference suite   (engine v${V16_VERSION})\n`);
  console.log('  log     recall   emitted  phantoms  tallest    height    airtime   distance');
  console.log('  ' + RULE);
  let recall = 0, goldens = 0, tallest = 0, negPh = 0;
  const allDh: number[] = [];
  for (const r of rows) {
    const f = (v: number, u = '') => isNaN(v) ? '   -   ' : (v.toFixed(2) + u).padStart(7);
    console.log(`  ${r.tag.padEnd(6)}  ${String(r.recall).padStart(2)}/${String(r.goldens).padEnd(2)}  ${String(r.emitted).padStart(6)}  ${String(r.phantoms).padStart(8)}  ${(r.tallest ? r.tallest.toFixed(2) + 'm' : '  -  ').padStart(7)}  ${f(r.heightMAE, 'm')}  ${f(r.airtimeMAE, 's')}  ${f(r.distMAE, 'm')}`);
    if (r.tag === 'NEG') { negPh = r.phantoms; continue }
    if (r.tag === 'BENCH') continue;            // throws are not part of the riding totals
    recall += r.recall; goldens += r.goldens; allDh.push(...r.dh);
    if (r.tallest > tallest) tallest = r.tallest;
  }
  const pooled = allDh.reduce((a, b) => a + Math.abs(b), 0) / allDh.length;
  console.log('  ' + RULE);
  console.log(`  riding totals: recall ${recall}/${goldens} - pooled height MAE ${pooled.toFixed(3)} m - tallest phantom ${tallest.toFixed(2)} m`);
  if (missing.length) console.log(`  (skipped, log not present: ${missing.join(', ')})`);

  const fails: string[] = [];
  if (negPh > GUARDS.negPhantoms) fails.push(`control session emitted ${negPh} (allowed ${GUARDS.negPhantoms})`);
  if (tallest > GUARDS.tallestPhantomM) fails.push(`tallest phantom ${tallest.toFixed(2)} m > ${GUARDS.tallestPhantomM} m`);
  if (recall < GUARDS.minRecall) fails.push(`recall ${recall} < ${GUARDS.minRecall}`);
  if (pooled > GUARDS.maxHeightMAE) fails.push(`pooled height MAE ${pooled.toFixed(3)} > ${GUARDS.maxHeightMAE}`);
  console.log('');
  if (fails.length) { for (const x of fails) console.log(`  FAIL  ${x}`); return 1 }
  console.log('  PASS  every guard-rail holds');
  return 0;
}

function one(path: string): number {
  const raw = decodeKslog2(new Uint8Array(readFileSync(path)));
  const em = analyseSessionV16(log5FromStreams(raw)).v16.emissions.map(e => e.jump);
  console.log(`\n${path}\nengine v${V16_VERSION} - ${em.length} jumps\n`);
  console.log('   #      t      height   airtime   distance  shelf   apexRaw  peakG');
  em.forEach((j, i) => console.log(
    `  ${String(i + 1).padStart(2)}  ${j.takeoffT.toFixed(1).padStart(7)}s  ${j.heightM.toFixed(2).padStart(6)}m  ` +
    `${(j.airtimeSec == null ? '  -  ' : j.airtimeSec.toFixed(2) + 's').padStart(7)}  ` +
    `${(j.distanceM == null ? '  -  ' : j.distanceM.toFixed(1) + 'm').padStart(8)}  ` +
    `${j.liftPlateauSec.toFixed(2)}s  ${j.apexRawM.toFixed(3).padStart(6)}  ${(j.peakG ?? 0).toFixed(1)}g`));
  return 0;
}

const args = process.argv.slice(2);
const json = args.includes('--json');
const file = args.find(a => !a.startsWith('--'));
process.exit(file ? one(file) : suite(json));
