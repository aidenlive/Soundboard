#!/usr/bin/env node
// Fails when a development default in code or configuration is missing from
// docs/guides/dev-logins.md (STATION §13). No dependencies.
//
//   node tools/logins/check.js
//
// Looks for: keys in .env.example, ports, seeded or other e-mail accounts, passwords and secrets
// with literal values, signing passwords, bundle and application IDs.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "../..");
const page = fs.readFileSync(path.join(ROOT, "docs/guides/dev-logins.md"), "utf8");

let files;
try {
  files = execFileSync("git", ["ls-files", "-co", "--exclude-standard"], { cwd: ROOT, encoding: "utf8" }).split("\n").filter(Boolean);
} catch {
  // Not a git checkout (an extracted dist zip): walk the tree, skipping build output.
  const skip = new Set([".git", "node_modules", "dist", "out", ".build", ".gradle"]);
  const walk = (d) => fs.readdirSync(path.join(ROOT, d), { withFileTypes: true }).flatMap((e) =>
    skip.has(e.name) || (e.isDirectory() && e.name.startsWith("build")) ? [] : e.isDirectory() ? walk(path.posix.join(d, e.name)) : [path.posix.join(d, e.name)]);
  files = walk(".").map((f) => f.replace(/^\.\//, ""));
}
const scanned = files.filter((f) =>
  fs.existsSync(path.join(ROOT, f)) &&
  !f.startsWith("docs/") && !f.startsWith("public/") && !f.startsWith(".archives/") && f !== "index.html" &&
  (/(^|\/)(Makefile|Dockerfile|\.env\.example)$/.test(f) || /\.(ya?ml|kts|gradle|properties|swift|kt|mjs|js|py|json|toml|cpp|hpp|h)$/.test(f)));

const RULES = [
  ["port", /localhost:(\d{2,5})/g],
  ["port", /\b[A-Z_]*PORT\s*(?:\?=|:=|=|\|\|)\s*["']?(\d{2,5})/g],
  ["port", /["'](\d{2,5}):\d{2,5}["']/g],
  ["account", /\b([\w.+-]+@[\w-]+(?:\.[\w-]+)*\.station\.center)\b/g],
  ["password", /\b(?:password|passwd|secret|token|api[_-]?key|storePassword|keyPassword)\b\s*[:=]\s*["']([^"'\s]{3,})["']/gi],
  ["bundle id", /PRODUCT_BUNDLE_IDENTIFIER:\s*([\w.-]+)/g],
  ["bundle id", /bundleIdPrefix:\s*([\w.-]+)/g],
  ["application id", /applicationId\s*=\s*"([\w.]+)"/g],
];

const missing = [];
for (const f of scanned) {
  const text = fs.readFileSync(path.join(ROOT, f), "utf8");
  if (f.endsWith(".env.example")) {
    for (const [, key] of text.matchAll(/^\s*([A-Z][A-Z0-9_]*)\s*=/gm)) if (!page.includes(key)) missing.push(`${f}: env ${key}`);
  }
  for (const [kind, re] of RULES) {
    for (const match of text.matchAll(re)) {
      const value = match[1];
      if (!page.includes(value)) missing.push(`${f}: ${kind} ${value}`);
    }
  }
}

if (missing.length) {
  console.error(`dev logins: ${missing.length} default(s) missing from docs/guides/dev-logins.md:\n  ${[...new Set(missing)].join("\n  ")}`);
  process.exit(1);
}
console.log(`dev logins: every default in ${scanned.length} files is listed`);
