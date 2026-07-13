import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const csvPath = path.join(
  root,
  "cloud_logs_20260711_latest_now/log_20260711_195534_8D524BE5.samples.csv"
);
const replayPath = path.join(
  root,
  "cloud_logs_20260711_latest_now/replay_v13_final/log_20260711_195534_8D524BE5.actual.json"
);

const lines = fs.readFileSync(csvPath, "utf8").trim().split(/\r?\n/);
const header = lines.shift().split(",");
const column = Object.fromEntries(header.map((name, index) => [name, index]));

const altitude = [];
let lastSensorTimestamp = null;
for (const line of lines) {
  const values = line.split(",");
  const sensorTimestamp = values[column.absAltRel];
  const altitudeM = values[column.absAlt];
  if (!sensorTimestamp || !altitudeM || sensorTimestamp === lastSensorTimestamp) continue;
  lastSensorTimestamp = sensorTimestamp;
  altitude.push({
    t: Number(values[column.t]),
    altitude: Number(altitudeM),
    accuracy: Number(values[column.absAltAcc]),
  });
}

const replay = JSON.parse(fs.readFileSync(replayPath, "utf8"));
const baselineByJump = [29.03, 28.70, 28.73];
const landingAltitudeByJump = [29.17, 29.24, 28.82];
const events = replay.jumps.map((jump, index) => ({
  index: index + 1,
  takeoff: jump.takeoffOffsetSec,
  apex: jump.takeoffOffsetSec + jump.apexTime,
  landing: jump.takeoffOffsetSec + jump.airtime,
  height: jump.height,
  airtime: jump.airtime,
  confidence: jump.confidence,
  rotations: jump.rotations,
  distance: jump.jumpDistance,
  baseline: baselineByJump[index],
  peak: baselineByJump[index] + jump.height,
  landingAltitude: landingAltitudeByJump[index],
}));

const payload = {
  source: {
    log: replay.file,
    durationSec: replay.durationSec,
    sampleCount: replay.sampleCount,
    detectedRateHz: replay.detectedRateHz,
    altitudeSampleCount: altitude.length,
  },
  altitude,
  events,
};

fs.writeFileSync(
  path.join(here, "report-data.js"),
  `window.REPORT_DATA = ${JSON.stringify(payload)};\n`
);

console.log(`Prepared ${altitude.length} absolute-altitude points and ${events.length} jumps.`);
