#!/usr/bin/env node
// Copies the version Changesets wrote to package.json into SDKInfo.swift, so
// the "Version Packages" PR bumps `LicenseManager.sdkVersion` too.

import { readFileSync, writeFileSync } from "node:fs";

const file = "Sources/LicenseManagerKit/SDKInfo.swift";
const { version } = JSON.parse(readFileSync("package.json", "utf8"));
const source = readFileSync(file, "utf8");
const pattern = /(public static let sdkVersion = ")[^"]*(")/;
if (!pattern.test(source)) {
	throw new Error(`No sdkVersion found in ${file}`);
}
writeFileSync(file, source.replace(pattern, `$1${version}$2`));
console.log(`licensemanager-swift set to ${version}`);
