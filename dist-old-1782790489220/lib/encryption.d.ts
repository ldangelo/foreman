/**
 * Encryption utilities for sensitive data (Jira tokens, webhook secrets).
 * Uses AES-256-GCM with a master key from FOREMAN_MASTER_KEY env var.
 */
/**
 * Get the master encryption key from environment.
 * Must be set via FOREMAN_MASTER_KEY env var.
 * Format: base64-encoded 32-byte key, or passphrase (derived with scrypt).
 */
export declare function getMasterKey(): Promise<Buffer>;
/**
 * Encrypt plaintext using AES-256-GCM.
 * Returns base64-encoded string: salt (32 bytes) + iv (16 bytes) + authTag (16 bytes) + ciphertext.
 */
export declare function encrypt(plaintext: string, masterKey?: Buffer): Promise<string>;
/**
 * Decrypt a base64-encoded ciphertext produced by encrypt().
 */
export declare function decrypt(encrypted: string, masterKey?: Buffer): Promise<string>;
/**
 * Generate a new random master key.
 * Use this to create FOREMAN_MASTER_KEY for initial setup.
 */
export declare function generateMasterKey(): string;
//# sourceMappingURL=encryption.d.ts.map