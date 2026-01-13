#!/usr/bin/env node
// Decrypt termix encrypted SQLite database
// Usage: decrypt.mjs <encrypted-db-path> <key-hex> <output-path>

import crypto from 'crypto';
import fs from 'fs';

const [,, encPath, keyHex, outPath] = process.argv;

if (!encPath || !keyHex || !outPath) {
  console.error('Usage: decrypt.mjs <encrypted-db-path> <key-hex> <output-path>');
  process.exit(1);
}

try {
  const fileBuffer = fs.readFileSync(encPath);

  // Parse single-file v2 format: [4-byte length][JSON metadata][encrypted data]
  const metaLen = fileBuffer.readUInt32BE(0);
  const metaEnd = 4 + metaLen;

  if (metaLen <= 0 || metaEnd > fileBuffer.length) {
    throw new Error('Invalid metadata length in encrypted file');
  }

  const metadataJson = fileBuffer.subarray(4, metaEnd).toString('utf8');
  const metadata = JSON.parse(metadataJson);
  const encData = fileBuffer.subarray(metaEnd);

  // Validate metadata
  if (!metadata.iv || !metadata.tag || !metadata.version) {
    throw new Error('Invalid metadata structure');
  }

  if (metadata.version !== 'v2') {
    throw new Error(`Unsupported encryption version: ${metadata.version}`);
  }

  if (metadata.algorithm !== 'aes-256-gcm') {
    throw new Error(`Unsupported algorithm: ${metadata.algorithm}`);
  }

  // Decrypt
  const key = Buffer.from(keyHex, 'hex');
  const iv = Buffer.from(metadata.iv, 'hex');
  const tag = Buffer.from(metadata.tag, 'hex');

  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);

  const decrypted = Buffer.concat([
    decipher.update(encData),
    decipher.final()
  ]);

  fs.writeFileSync(outPath, decrypted);
  console.log(`Decrypted ${encPath} -> ${outPath}`);

} catch (error) {
  console.error(`Decryption failed: ${error.message}`);
  process.exit(1);
}
