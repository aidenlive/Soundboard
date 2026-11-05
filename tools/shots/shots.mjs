#!/usr/bin/env node
// Screenshots with headless Chrome. No dependencies.
//
//   node tools/shots/shots.mjs            docs/screenshot.png (landing, dark, 1440 wide)
//                                         + dist/shots/<page>-<width>-<scheme>.png for review
//
// Pages: landing, docs overview, design kit, system graph, root resource page.
// Widths 390 (phone) and 1440 (desktop); schemes dark and light.
// Set CHROME to a Chrome or Chromium binary if it is not on PATH.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const candidates = [process.env.CHROME, "google-chrome", "chromium", "chromium-browser",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"].filter(Boolean);
const which = (b) => { try { execFileSync(b, ["--version"], { stdio: "ignore" }); return true; } catch { return false; } };
const chrome = candidates.find(which);
if (!chrome) { console.error("shots: no Chrome found; set CHROME=/path/to/chrome"); process.exit(1); }

const pages = { landing: "public/index.html", docs: "public/docs/index.html", design: "public/design/index.html", system: "public/system/index.html", resource: "index.html" };
const shot = (file, out, width, height, scheme) => {
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const args = ["--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", `--window-size=${width},${height}`,
    `--screenshot=${out}`, "--virtual-time-budget=2000"];
  if (scheme === "dark") args.push("--force-dark-mode");
  args.push(pathToFileURL(path.join(ROOT, file)).href);
  execFileSync(chrome, args, { stdio: "ignore", timeout: 60000 });
};

shot(pages.landing, path.join(ROOT, "docs/screenshot.png"), 1440, 1000, "dark");
console.log("shots: docs/screenshot.png");
for (const [name, file] of Object.entries(pages))
  for (const width of [390, 1440])
    for (const scheme of ["dark", "light"])
      shot(file, path.join(ROOT, `dist/shots/${name}-${width}-${scheme}.png`), width, width === 390 ? 2400 : 1800, scheme);
console.log("shots: dist/shots/ (5 pages × 2 widths × 2 schemes)");
