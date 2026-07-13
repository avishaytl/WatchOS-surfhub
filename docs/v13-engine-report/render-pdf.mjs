import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium } from "/tmp/v13-pdf-tools/node_modules/playwright/index.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const inputName = process.argv[2] ?? "report.html";
const outputName = process.argv[3] ?? "V13_Engine_13_End_to_End_HE.pdf";
const previewName = process.argv[4] ?? "preview";
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({
  viewport: { width: 794, height: 1123 },
  deviceScaleFactor: 2,
});

await page.goto(pathToFileURL(path.join(here, inputName)).href, {
  waitUntil: "networkidle",
});
await page.evaluate(async () => {
  await document.fonts.ready;
  if (window.reportReady) await window.reportReady;
});

const issues = await page.evaluate(() => {
  const results = [];
  document.querySelectorAll(".page").forEach((element, index) => {
    if (
      element.scrollHeight > element.clientHeight + 1 ||
      element.scrollWidth > element.clientWidth + 1
    ) {
      results.push({
        page: index + 1,
        scrollHeight: element.scrollHeight,
        clientHeight: element.clientHeight,
        scrollWidth: element.scrollWidth,
        clientWidth: element.clientWidth,
      });
    }
  });
  return results;
});
if (issues.length) {
  throw new Error(`Page overflow detected: ${JSON.stringify(issues)}`);
}

await page.pdf({
  path: path.join(here, outputName),
  format: "A4",
  printBackground: true,
  preferCSSPageSize: true,
  margin: { top: "0", right: "0", bottom: "0", left: "0" },
});

const previewDir = path.join(here, previewName);
fs.mkdirSync(previewDir, { recursive: true });
for (const entry of fs.readdirSync(previewDir)) {
  if (entry.endsWith(".png")) fs.unlinkSync(path.join(previewDir, entry));
}

const pages = page.locator(".page");
const pageCount = await pages.count();
for (let index = 0; index < pageCount; index += 1) {
  await pages.nth(index).screenshot({
    path: path.join(previewDir, `page-${String(index + 1).padStart(2, "0")}.png`),
  });
}

await browser.close();
console.log(`Rendered ${pageCount} pages with no overflow.`);
