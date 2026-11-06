#!/usr/bin/env node
// Cross-SDK storage compatibility check with @licenseman/electron.
//
//   node scripts/compat/electron-store.mjs write <dir>
//     Installs @licenseman/electron (without optional deps, so it stores in
//     files only), lets it create an install in <dir>/storage and writes what
//     it computed to <dir>/expected.json. The Swift test
//     "reads and writes the same files as @licenseman/electron" then opens
//     the same storage (LICENSEMANAGER_COMPAT_DIR=<dir>) and stores a key.
//
//   node scripts/compat/electron-store.mjs read <dir>
//     Opens <dir>/storage with the Electron SDK and checks it reads the
//     license key written by the Swift SDK.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";

const PRODUCT_ID = "x7Kp2QaZ";
const MACHINE = "compat-machine";
const ELECTRON_SDK_VERSION = process.env.ELECTRON_SDK_VERSION ?? "1.3.0";

const [mode, dirArg] = process.argv.slice(2);
if ((mode !== "write" && mode !== "read") || !dirArg) {
	console.error("usage: electron-store.mjs <write|read> <dir>");
	process.exit(2);
}
const dir = resolve(dirArg);
const nodeDir = join(dir, "node");
const storageDir = join(dir, "storage");

function loadElectronSdk() {
	const entry = join(nodeDir, "node_modules", "@licenseman", "electron");
	if (!existsSync(entry)) {
		mkdirSync(nodeDir, { recursive: true });
		writeFileSync(join(nodeDir, "package.json"), '{ "private": true }\n');
		execFileSync(
			"npm",
			[
				"install",
				"--no-save",
				"--no-audit",
				"--no-fund",
				"--omit=optional",
				"--legacy-peer-deps",
				`@licenseman/electron@${ELECTRON_SDK_VERSION}`,
			],
			{ cwd: nodeDir, stdio: ["ignore", "inherit", "inherit"] },
		);
	}
	return createRequire(join(nodeDir, "package.json"))("@licenseman/electron");
}

function open() {
	const { LicenseManager } = loadElectronSdk();
	return new LicenseManager({
		productId: PRODUCT_ID,
		// Never used: no key is validated.
		publicKey: "unused",
		fingerprint: MACHINE,
		version: "1.0.0",
		apiBaseUrl: "http://127.0.0.1:9",
		useKeychain: false,
		storageDirs: [storageDir],
	});
}

mkdirSync(storageDir, { recursive: true });
const manager = open();
if (mode === "read") {
	const licenseKey = manager.getLicenseKey();
	manager.dispose();
	if (licenseKey !== "WRITTEN-BY-SWIFT") {
		console.error(`Electron read ${JSON.stringify(licenseKey)}, expected "WRITTEN-BY-SWIFT"`);
		process.exit(1);
	}
	console.log("Electron reads what the Swift SDK wrote");
	process.exit(0);
}

const fingerprint = await manager.getFingerprint();
manager.dispose();
const expected = {
	productId: PRODUCT_ID,
	machine: MACHINE,
	fingerprint,
	installId: fingerprint.split(":")[1],
};
writeFileSync(join(dir, "expected.json"), `${JSON.stringify(expected, null, 2)}\n`);
console.log(`Electron fingerprint: ${fingerprint}`);
process.exit(0);
