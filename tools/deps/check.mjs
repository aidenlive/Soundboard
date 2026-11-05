#!/usr/bin/env node
// Dependency pin check (the "lockfile platform check" step of `make validate`). No dependencies.
//
// This repository has no lockfile: the engine has no dependencies, the Swift package has none,
// and Android pins exact versions in a Gradle version catalog. The check keeps it that way:
//   - every version in platforms/android/gradle/libs.versions.toml is exact (no +, ranges, latest)
//   - no Gradle build file declares a dependency or plugin version inline
//   - Package.swift declares no package dependencies, or Package.resolved is committed
//   - engine/CMakeLists.txt fetches nothing (no FetchContent or ExternalProject)

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (p) => fs.readFileSync(path.join(ROOT, p), "utf8");
const exists = (p) => fs.existsSync(path.join(ROOT, p));
const errors = [];

const catalog = "platforms/android/gradle/libs.versions.toml";
if (exists(catalog)) {
  const versions = read(catalog).split("[libraries]")[0];
  for (const [, name, value] of versions.matchAll(/^(\w[\w-]*)\s*=\s*"([^"]*)"/gm))
    if (!/^\d+(\.\d+)*(-[\w.]+)?$/.test(value)) errors.push(`${catalog}: ${name} = "${value}" is not an exact version`);
}
for (const f of ["platforms/android/build.gradle.kts", "platforms/android/app/build.gradle.kts", "platforms/android/settings.gradle.kts"].filter(exists)) {
  const s = read(f);
  for (const [line] of s.matchAll(/^.*\b(implementation|api|testImplementation|androidTestImplementation)\s*\(\s*"[^"]+:[^"]+".*$/gm))
    errors.push(`${f}: inline dependency, move it to the version catalog: ${line.trim()}`);
  for (const [line] of s.matchAll(/^.*:\+".*$|^.*latest\.(release|integration).*$/gm)) errors.push(`${f}: dynamic version: ${line.trim()}`);
}
if (/\.package\s*\(/.test(read("Package.swift")) && !exists("Package.resolved")) errors.push("Package.swift has dependencies but Package.resolved is not committed");
if (/FetchContent|ExternalProject_Add/.test(read("engine/CMakeLists.txt"))) errors.push("engine/CMakeLists.txt fetches a dependency; pin it and add an ADR");

if (errors.length) {
  console.error(`dependency pins: ${errors.length} problem(s)\n  ${errors.join("\n  ")}`);
  process.exit(1);
}
console.log("dependency pins: exact versions only; no lockfile needed (engine and Swift have no dependencies)");
