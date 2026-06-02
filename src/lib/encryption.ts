/**
 * Encryption utilities for sensitive data (Jira tokens, webhook secrets).
 * Uses AES-256-GCM with a master key from FOREMAN_MASTER_KEY env var.
 */

import { createCipheriv, createDecipheriv, randomBytes, scrypt } from "node:crypto";
import { promisify } from "node:util";

const scryptAsync = promisify(scrypt);

const ALGORITHM = "aes-256-gcm";
const IV_LENGTH = 16;
const AUTH_TAG_LENGTH = 16;
const SALT_LENGTH = 32;
const KEY_LENGTH = 32;

/**
 * Get the master encryption key from environment.
 * Must be set via FOREMAN_MASTER_KEY env var.
 * Format: base64-encoded 32-byte key, or passphrase (derived with scrypt).
 */
export async function getMasterKey(): Promise<Buffer> {
  const envKey = process.env.FOREMAN_MASTER_KEY;
  if (!envKey) {
    throw new Error(
      "FOREMAN_MASTER_KEY environment variable is not set. " +
        "Generate a key with: openssl rand -base64 32"
    );
  }
  // If it looks like base64 (32+ chars, no spaces), decode it
  if (envKey.length >= 44 && /^[A-Za-z0-9+/=]+$/.test(envKey)) {
    const decoded = Buffer.from(envKey, "base64");
    if (decoded.length === KEY_LENGTH) {
      return decoded;
    }
    // If it's valid base64 but wrong length, use as passphrase
  }
  // Treat as passphrase and derive key
  return await deriveKey(envKey, "foreman-master-salt-v1");
}

/**
 * Derive a 32-byte key from a passphrase using scrypt.
 */
async function deriveKey(passphrase: string, salt: string): Promise<Buffer> {
  return (await scryptAsync(passphrase, salt, KEY_LENGTH)) as Buffer;
}

/**
 * Encrypt plaintext using AES-256-GCM.
 * Returns base64-encoded string: salt (32 bytes) + iv (16 bytes) + authTag (16 bytes) + ciphertext.
 */
export async function encrypt(plaintext: string, masterKey?: Buffer): Promise<string> {
  const key = masterKey ?? (await getMasterKey());
  const salt = randomBytes(SALT_LENGTH);
  const iv = randomBytes(IV_LENGTH);
  const cipher = createCipheriv(ALGORITHM, key, iv);
  let ciphertext = cipher.update(plaintext, "utf8");
  ciphertext = Buffer.concat([ciphertext, cipher.final()]);
  const authTag = cipher.getAuthTag();
  // Combine: salt + iv + authTag + ciphertext
  const result = Buffer.concat([salt, iv, authTag, ciphertext]);
  return result.toString("base64");
}
/**
 * Decrypt a base64-encoded ciphertext produced by encrypt().
 */
export async function decrypt(encrypted: string, masterKey?: Buffer): Promise<string> {
  const key = masterKey ?? (await getMasterKey());
  const data = Buffer.from(encrypted, "base64");
  if (data.length < SALT_LENGTH + IV_LENGTH + AUTH_TAG_LENGTH) {
    throw new Error("Invalid encrypted data: too short");
  }

  const salt = data.subarray(0, SALT_LENGTH);
  const iv = data.subarray(SALT_LENGTH, SALT_LENGTH + IV_LENGTH);
  const authTag = data.subarray(
    SALT_LENGTH + IV_LENGTH,
    SALT_LENGTH + IV_LENGTH + AUTH_TAG_LENGTH,
  );
  const ciphertext = data.subarray(SALT_LENGTH + IV_LENGTH + AUTH_TAG_LENGTH);

  const decipher = createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(authTag);

  let plaintext = decipher.update(ciphertext);
  plaintext = Buffer.concat([plaintext, decipher.final()]);

  return plaintext.toString("utf8");
}

/**
 * Generate a new random master key.
 * Use this to create FOREMAN_MASTER_KEY for initial setup.
 */
export function generateMasterKey(): string {
  return randomBytes(KEY_LENGTH).toString("base64");
}