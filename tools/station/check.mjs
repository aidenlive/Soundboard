#!/usr/bin/env node
// Station 1.2.1 lint for this repository. No dependencies.
//
//   node tools/station/check.mjs             layout, manifest, versions, README, .station/, ADRs,
//                                            archives, Markdown links, site CSS token use
//   node tools/station/check.mjs --release   also requires the git tag v<version>
//
// Exits 1 and lists every failure. Rules: STATION_1_2_1 §5, §6, §8, §14 and the delivery checklist.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const abs = (p) => path.join(ROOT, p);
const exists = (p) => fs.existsSync(abs(p));
const read = (p) => fs.readFileSync(abs(p), "utf8");
const errors = [];
const warnings = [];
const fail = (msg) => errors.push(msg);
const release = process.argv.includes("--release");

// ---------------------------------------------------------------- §5 root files
for (const f of ["README.md", "AGENTS.md", "ROADMAP.md", "CHANGELOG.md", "LICENSE", "SECURITY.md", "CONTRIBUTORS.md",
  "station.json", ".station", ".github", "docs", "public", "index.html", "Makefile"]) if (!exists(f)) fail(`missing ${f}`);
if (!["deploy", "infra", "docker"].some(exists)) fail("missing deploy/ (or infra/ or docker/)");
for (const f of ["docs/guides", "docs/decisions", "docs/architecture.md", "docs/README.md", ".github/workflows",
  ".github/PULL_REQUEST_TEMPLATE.md", ".github/ISSUE_TEMPLATE"]) if (!exists(f)) fail(`missing ${f}`);

// ---------------------------------------------------------------- §2 manifest
const m = JSON.parse(read("station.json"));
for (const k of ["id", "name", "purpose", "version", "status", "organization", "role", "landing"]) if (!m[k]) fail(`station.json: ${k} is empty`);
if (!("sponsor" in m)) fail("station.json: sponsor missing");
if (!["draft", "stable", "deprecated"].includes(m.status)) fail(`station.json: status ${m.status} is not draft · stable · deprecated`);
if (!/^\d+\.\d+\.\d+(-[\w.]+)?$/.test(m.version || "")) fail(`station.json: version ${m.version} is not semver`);
if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(m.role || "")) fail(`station.json: role ${m.role} must be lowercase words joined by hyphens`);
if (m.tier && !["open", "internal"].includes(m.tier)) fail(`station.json: tier ${m.tier}`);
if (m.tier === "internal" && m.sponsor !== null) fail("station.json: an internal repository has sponsor null");
for (const k of m.kept || []) if (!exists(k)) fail(`station.json: kept path ${k} does not exist`);

// ---------------------------------------------------------------- version agreement
const v = m.version;
const top = read("CHANGELOG.md").match(/^## (\S+) · (\d{4}-\d{2}-\d{2})/m);
if (!top) fail("CHANGELOG.md: no '## <version> · <YYYY-MM-DD>' entry");
else if (top[1] !== v) fail(`CHANGELOG.md top entry ${top[1]} ≠ station.json ${v}`);
const pinned = [
  ["engine/CMakeLists.txt", /project\(\w+ VERSION (\S+)/],
  ["platforms/apple/project.yml", /MARKETING_VERSION: "([^"]+)"/],
  ["platforms/android/app/build.gradle.kts", /versionName = "([^"]+)"/],
];
for (const [f, re] of pinned) {
  const got = exists(f) && read(f).match(re);
  if (!got) fail(`${f}: version not found`);
  else if (got[1] !== v) fail(`${f}: version ${got[1]} ≠ ${v}`);
}
for (const f of walk(".").filter((p) => p.endsWith("package.json"))) {
  const pj = JSON.parse(read(f));
  if (pj.version !== v) fail(`${f}: version ${pj.version} ≠ ${v}`);
}
let tags = [];
try { tags = execFileSync("git", ["tag", "--list", "v*"], { cwd: ROOT, encoding: "utf8" }).split("\n").filter(Boolean); } catch { /* not a checkout */ }
if (!tags.includes(`v${v}`)) (release ? fail : (msg) => warnings.push(msg))(`git tag v${v} does not exist yet`);
const newer = tags.map((t) => t.slice(1)).filter((t) => cmp(t, v) > 0);
if (newer.length) fail(`git tags newer than station.json version ${v}: ${newer.join(", ")}`);

// ---------------------------------------------------------------- §3 README
const readme = read("README.md");
const h1 = readme.match(/^# .+$/gm) || [];
const h2 = (readme.match(/^## .+$/gm) || []).map((h) => h.slice(3).trim());
if (h1.length !== 1 || h1[0] !== `# ${m.name}`) fail(`README.md: one H1 "# ${m.name}" required`);
if (JSON.stringify(h2) !== JSON.stringify(["Start", "Layout", "Links", "Sponsor"])) fail(`README.md: sections must be Start, Layout, Links, Sponsor; found ${h2.join(", ")}`);
if (!/!\[[^\]]*\]\(docs\/screenshot\.png\)/.test(readme)) fail("README.md: picture docs/screenshot.png under the one line");
if (!exists("docs/screenshot.png")) fail("docs/screenshot.png missing (make shots)");
for (const d of ["public/", "index.html", "tools/", ".archives/"]) if (!readme.includes(d)) fail(`README.md Layout: does not mention ${d}`);
if (m.tier === "internal" && !/## Sponsor\s+None is recorded/.test(readme)) fail("README.md Sponsor: internal repositories say none is recorded");

// ---------------------------------------------------------------- §4 .station/
const cfg = exists(".station/config.json") ? JSON.parse(read(".station/config.json")) : {};
if (cfg.scope !== "project" || cfg.standard !== "station@1.2.1") fail('.station/config.json must be { "scope": "project", "standard": "station@1.2.1" }');
const allowed = new Set(["config.json", "STATUS.md", "jobs", "decisions"]);
for (const f of fs.readdirSync(abs(".station"))) if (!allowed.has(f)) fail(`.station/${f}: does not trace to STATION §3`);
const status = exists(".station/STATUS.md") ? read(".station/STATUS.md") : "";
if (!status.includes(`Version ${v}`)) fail(`.station/STATUS.md: first line must state Version ${v}`);
for (const h of ["## What passes", "## Open", "## Jobs"]) if (!status.includes(h)) fail(`.station/STATUS.md: missing ${h}`);
if (!/## Open\s+\| Item \| Owner \| Note \|/.test(status)) fail(".station/STATUS.md: Open table needs Item · Owner · Note");
const HEADINGS = ["Objective", "Completed", "Active", "Blockers", "Decisions", "Files changed", "Verification", "Next actions"];
const WORDS = ["PLANNED", "ACTIVE", "BLOCKED", "DONE", "ARCHIVED"];
for (const job of fs.readdirSync(abs(".station/jobs")).sort()) {
  if (!/^\d{3}-[a-z0-9-]+$/.test(job)) fail(`.station/jobs/${job}: name must be NNN-slug`);
  const f = `.station/jobs/${job}/SESSION.md`;
  if (!exists(f)) { fail(`${f} missing`); continue; }
  const s = read(f);
  const hs = (s.match(/^## .+$/gm) || []).map((h) => h.slice(3));
  if (JSON.stringify(hs) !== JSON.stringify(HEADINGS)) fail(`${f}: headings must be ${HEADINGS.join(", ")}`);
  const word = (s.match(/^Status: (\w+)$/m) || [])[1];
  if (!WORDS.includes(word)) fail(`${f}: Status must be one of ${WORDS.join(" · ")}`);
  const row = status.match(new RegExp(`\\(jobs/${job}/SESSION\\.md\\) \\| (\\w+) \\|`));
  if (!row) fail(`.station/STATUS.md: Jobs list lacks ${job}`);
  else if (row[1] !== word) fail(`.station/STATUS.md: ${job} is ${row[1]} but SESSION.md says ${word}`);
}

// ---------------------------------------------------------------- §5 docs
for (const g of ["local-development.md", "deploy.md", "dev-logins.md", "qa.md"]) if (!exists(`docs/guides/${g}`)) fail(`docs/guides/${g} missing`);
const arch = read("docs/architecture.md");
for (const w of ["public/", "Boundaries", "Data model", "Surfaces", "Testing strategy"]) if (!arch.includes(w)) fail(`docs/architecture.md: missing ${w}`);
for (const f of fs.readdirSync(abs("docs/decisions")).filter((f) => f !== "README.md")) {
  if (!/^\d{4}-[a-z0-9-]+\.md$/.test(f)) { fail(`docs/decisions/${f}: name must be NNNN-slug.md`); continue; }
  const s = read(`docs/decisions/${f}`);
  if (!/^Status · \w+ · \d{4}-\d{2}-\d{2}$/m.test(s)) fail(`docs/decisions/${f}: needs "Status · <state> · <date>"`);
  for (const h of ["## Context", "## Decision", "## Consequences"]) if (!s.includes(h)) fail(`docs/decisions/${f}: missing ${h}`);
}

// ---------------------------------------------------------------- §10 archives
if (!exists(".archives/removal-safe/README.md")) fail(".archives/removal-safe/README.md missing");
else {
  const idx = read(".archives/removal-safe/README.md");
  for (const d of fs.readdirSync(abs(".archives/removal-safe")).filter((d) => d !== "README.md")) {
    if (!exists(`.archives/removal-safe/${d}/README.md`)) fail(`.archives/removal-safe/${d}: README missing`);
    if (!idx.includes(`(${d}/README.md)`)) fail(`.archives/removal-safe/README.md: no row for ${d}`);
  }
}
const reports = exists(".archives/audit-reports") ? fs.readdirSync(abs(".archives/audit-reports")) : [];
for (const n of ["000", "001"]) if (!reports.some((r) => r.startsWith(`${n}-`))) fail(`.archives/audit-reports/${n}-*.md missing`);
for (const r of reports) if (!/^\d{3}-[a-z0-9-]+\.md$/.test(r)) fail(`.archives/audit-reports/${r}: name must be NNN-slug.md`);

// ---------------------------------------------------------------- §6 public surface
for (const f of ["public/index.html", "public/design/DESIGN.md", "public/design/tokens.css", "public/design/system.json",
  "public/design/overrides.json", "public/design/index.html", "public/system/index.html", "public/docs/index.html",
  "public/llm.txt", "public/assets/site.css"]) if (!exists(f)) fail(`missing ${f}`);
const css = read("public/assets/site.css").replace(/\/\*[\s\S]*?\*\//g, "");
const cssNoFace = css.replace(/@font-face\s*{[^}]*}/g, "");
const colour = cssNoFace.match(/#[0-9a-fA-F]{3,8}\b|\b(rgba?|hsla?|oklch|oklab|lab|lch)\(|\b(white|black|red|blue|green|gray|grey)\b/g);
if (colour) fail(`public/assets/site.css: raw colours ${[...new Set(colour)].join(", ")}`);
if (/font-family:\s*["'A-Z]/.test(cssNoFace)) fail("public/assets/site.css: raw font-family (use var(--font-*))");
const pxOutsideMedia = cssNoFace.split("\n").filter((l) => !l.trim().startsWith("@media") && /\b\d*\.?\d+(px|rem)\b/.test(l));
if (pxOutsideMedia.length) fail(`public/assets/site.css: raw sizes outside @media:\n    ${pxOutsideMedia.map((l) => l.trim()).join("\n    ")}`);
for (const f of ["public/index.html"]) {
  const s = read(f);
  if (/style="[^"]*(#[0-9a-f]{3,8}|rgb|oklch|\d+px)/i.test(s)) fail(`${f}: inline raw style value`);
}

// ---------------------------------------------------------------- §14 generated headers
for (const f of ["public/design/DESIGN.md", "public/design/tokens.css", "public/design/tokens.json", "public/llm.txt",
  "index.html", "public/design/index.html", "public/system/index.html",
  "platforms/apple/Sources/SoundboardUI/Design/ObsidianTokens.generated.swift"]) {
  if (exists(f) && !/Generated by/.test(read(f).slice(0, 600))) fail(`${f}: generated file without a "Generated by" header`);
}

// ---------------------------------------------------------------- relative links in Markdown
for (const f of walk(".").filter((p) => p.endsWith(".md") && !p.startsWith("public/"))) {
  const text = read(f).replace(/```[\s\S]*?```/g, "").replace(/`[^`]*`/g, "");
  for (const [, href] of text.matchAll(/\]\(([^)\s]+)\)/g)) {
    if (/^(https?:|mailto:|#)/.test(href)) continue;
    const target = path.posix.normalize(path.posix.join(path.posix.dirname(f), href.split("#")[0]));
    if (!exists(target)) fail(`${f}: broken link ${href}`);
  }
}

// ---------------------------------------------------------------- report
for (const w of warnings) console.warn(`station: note: ${w}`);
if (errors.length) {
  console.error(`station: ${errors.length} problem(s)\n  ${errors.join("\n  ")}`);
  process.exit(1);
}
console.log("station: layout, manifest, versions, README, .station/, docs, archives, public/ and links OK");

// ---------------------------------------------------------------- helpers
function cmp(a, b) {
  const pa = a.split(/[.-]/).map(Number), pb = b.split(/[.-]/).map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0);
  return 0;
}
function walk(dir) {
  // Tracked files when in a git checkout; otherwise a filesystem walk without build output.
  try {
    return execFileSync("git", ["ls-files", "-co", "--exclude-standard"], { cwd: ROOT, encoding: "utf8" }).split("\n").filter(Boolean).filter(exists);
  } catch {
    const skip = new Set([".git", "node_modules", "dist", ".build", "out", ".gradle"]);
    const go = (d) => fs.readdirSync(abs(d), { withFileTypes: true }).flatMap((e) => skip.has(e.name) || (e.isDirectory() && e.name.startsWith("build")) ? [] :
      e.isDirectory() ? go(path.posix.join(d, e.name)) : [path.posix.join(d, e.name)]);
    return go(dir).map((p) => p.replace(/^\.\//, ""));
  }
}
