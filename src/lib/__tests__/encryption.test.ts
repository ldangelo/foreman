import { afterEach, describe, expect, it } from "vitest";

import { decrypt, encrypt, generateMasterKey, getMasterKey } from "../encryption.js";

const originalMasterKey = process.env.FOREMAN_MASTER_KEY;

afterEach(() => {
  if (originalMasterKey === undefined) {
    delete process.env.FOREMAN_MASTER_KEY;
  } else {
    process.env.FOREMAN_MASTER_KEY = originalMasterKey;
  }
});

describe("encryption utilities", () => {
  it("generates a base64 master key and accepts it from the environment", async () => {
    const generated = generateMasterKey();
    process.env.FOREMAN_MASTER_KEY = generated;

    const key = await getMasterKey();

    expect(Buffer.from(generated, "base64")).toHaveLength(32);
    expect(key).toEqual(Buffer.from(generated, "base64"));
  });

  it("derives a stable key from passphrases and non-32-byte base64 values", async () => {
    process.env.FOREMAN_MASTER_KEY = "correct horse battery staple";
    const passphraseKey = await getMasterKey();
    expect(passphraseKey).toHaveLength(32);
    await expect(getMasterKey()).resolves.toEqual(passphraseKey);

    process.env.FOREMAN_MASTER_KEY = Buffer.from("short").toString("base64").padEnd(44, "=");
    const shortBase64Key = await getMasterKey();
    expect(shortBase64Key).toHaveLength(32);
    expect(shortBase64Key).not.toEqual(passphraseKey);
  });

  it("requires FOREMAN_MASTER_KEY when no key is provided", async () => {
    delete process.env.FOREMAN_MASTER_KEY;

    await expect(getMasterKey()).rejects.toThrow("FOREMAN_MASTER_KEY environment variable is not set");
    await expect(encrypt("secret")).rejects.toThrow("FOREMAN_MASTER_KEY environment variable is not set");
  });

  it("round-trips encrypted text with an explicit master key", async () => {
    const key = Buffer.alloc(32, 7);

    const encrypted = await encrypt("jira-token", key);

    expect(encrypted).not.toBe("jira-token");
    await expect(decrypt(encrypted, key)).resolves.toBe("jira-token");
  });

  it("rejects invalid encrypted payloads and wrong keys", async () => {
    const key = Buffer.alloc(32, 1);
    const wrongKey = Buffer.alloc(32, 2);
    const encrypted = await encrypt("webhook-secret", key);

    await expect(decrypt(Buffer.from("too-short").toString("base64"), key)).rejects.toThrow("Invalid encrypted data: too short");
    await expect(decrypt(encrypted, wrongKey)).rejects.toThrow();
  });
});
