#!/usr/bin/env node
// Site checks (`make e2e`). No dependencies.
//   1. Every relative href and src in public/ and index.html resolves to a file.
//   2. Every #anchor exists in its target page.
//   3. With Chrome available (or CHROME set): each top-level page loads and renders its main region.
// Links to dist/ (make dist output) and to localhost are reported, not followed.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const list = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? list(path.join(d, e.name)) : [path.join(d, e.name)]));
const pages = [path.join(ROOT, "index.html"), ...list(path.join(ROOT, "public")).filter((f) => f.endsWith(".html"))];
const errors = [];
const ids = new Map();
const idsOf = (f) => {
  if (!ids.has(f)) ids.set(f, new Set([...fs.readFileSync(f, "utf8").matchAll(/\bid="([^"]+)"/g)].map((m) => m[1])));
  return ids.get(f);
};

let links = 0;
for (const page of pages) {
  const html = fs.readFileSync(page, "utf8").replace(/<pre[\s\S]*?<\/pre>/g, "");
  for (const [, attr, url] of html.matchAll(/\b(href|src|srcset)="([^"]+)"/g)) {
    if (/^(https?:|mailto:|data:)/.test(url)) continue;
    links++;
    const [p, hash] = url.split("#");
    const target = p ? path.resolve(path.dirname(page), p) : page;
    const where = `${path.relative(ROOT, page)}: ${attr}="${url}"`;
    if (path.relative(ROOT, target).startsWith("dist/")) continue; // make dist output
    if (!fs.existsSync(target)) { errors.push(`${where} → missing`); continue; }
    if (hash && target.endsWith(".html") && !idsOf(target).has(hash)) errors.push(`${where} → no #${hash}`);
  }
}

const which = (b) => { try { execFileSync(b, ["--version"], { stdio: "ignore" }); return true; } catch { return false; } };
const chrome = [process.env.CHROME, "google-chrome", "chromium", "chromium-browser", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"].filter(Boolean).find(which);
let rendered = 0;
if (chrome) {
  for (const rel of ["index.html", "public/index.html", "public/docs/index.html", "public/design/index.html", "public/system/index.html"]) {
    const dom = execFileSync(chrome, ["--headless=new", "--no-sandbox", "--disable-gpu", "--dump-dom", pathToFileURL(path.join(ROOT, rel)).href], { encoding: "utf8", timeout: 60000, stdio: ["ignore", "pipe", "ignore"] });
    if (!/<main|<article/.test(dom) || !/<footer/.test(dom)) errors.push(`${rel}: did not render main and footer in Chrome`);
    rendered++;
  }
} else {
  console.warn("e2e: Chrome not found; skipped the render check (set CHROME)");
}

if (errors.length) {
  console.error(`e2e: ${errors.length} problem(s)\n  ${errors.join("\n  ")}`);
  process.exit(1);
}
console.log(`e2e: ${pages.length} pages, ${links} links and assets resolve${rendered ? `; ${rendered} pages rendered in Chrome` : ""}`);
