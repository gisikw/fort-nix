#!/usr/bin/env node
// Encrypt SQLite database in termix format
// Usage: encrypt.mjs <input-db-path> <key-hex> <output-path>

import crypto from 'crypto';
import fs from 'fs';

const [,, inPath, keyHex, outPath] = process.argv;

if (!inPath || !keyHex || !outPath) {
  console.error('Usage: encrypt.mjs <input-db-path> <key-hex> <output-path>');
  process.exit(1);
}

try {
  const plaintext = fs.readFileSync(inPath);
  const key = Buffer.from(keyHex, 'hex');
  const iv = crypto.randomBytes(16);

  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([
    cipher.update(plaintext),
    cipher.final()
  ]);
  const tag = cipher.getAuthTag();

  // Build metadata matching termix's format
  const metadata = JSON.stringify({
    iv: iv.toString('hex'),
    tag: tag.toString('hex'),
    version: 'v2',
    fingerprint: 'termix-v2-systemcrypto',
    algorithm: 'aes-256-gcm',
    keySource: 'SystemCrypto',
    dataSize: encrypted.length
  });

  const metaBuffer = Buffer.from(metadata, 'utf8');
  const lenBuffer = Buffer.alloc(4);
  lenBuffer.writeUInt32BE(metaBuffer.length, 0);

  // Write single-file v2 format: [4-byte length][JSON metadata][encrypted data]
  const finalBuffer = Buffer.concat([lenBuffer, metaBuffer, encrypted]);

  // Atomic write: write to temp, then rename
  const tmpPath = `${outPath}.tmp-${process.pid}`;
  fs.writeFileSync(tmpPath, finalBuffer);
  fs.renameSync(tmpPath, outPath);

  console.log(`Encrypted ${inPath} -> ${outPath}`);

} catch (error) {
  console.error(`Encryption failed: ${error.message}`);
  process.exit(1);
}
