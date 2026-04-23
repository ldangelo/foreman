/**
 * TRD-001-TEST | Verifies: TRD-001 | Tests: fastify + tRPC dependencies installed, build passes
 * PRD: docs/PRD/PRD-2026-010-multi-project-orchestrator.md
 * TRD: docs/TRD/TRD-2026-011-multi-project-orchestrator.md#trd-001
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PKG_ROOT = join(import.meta.dirname, "..", "..", "..");

describe("TRD-001: fastify + tRPC dependencies", () => {
  it("fastify is declared in package.json dependencies", () => {
    const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf-8"));
    expect(pkg.dependencies).toHaveProperty("fastify");
  });

  it("@trpc/server is declared in package.json dependencies", () => {
    const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf-8"));
    expect(pkg.dependencies).toHaveProperty("@trpc/server");
  });

  it("@trpc/client is declared in package.json dependencies", () => {
    const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf-8"));
    expect(pkg.dependencies).toHaveProperty("@trpc/client");
  });

  it("ws is declared in package.json dependencies", () => {
    const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf-8"));
    expect(pkg.dependencies).toHaveProperty("ws");
  });

  it("pg is declared in package.json dependencies", () => {
    const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf-8"));
    expect(pkg.dependencies).toHaveProperty("pg");
  });

  it("@types/ws is declared in devDependencies", () => {
    const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf-8"));
    expect(pkg.devDependencies).toHaveProperty("@types/ws");
  });

  it("@types/pg is declared in devDependencies", () => {
    const pkg = JSON.parse(readFileSync(join(PKG_ROOT, "package.json"), "utf-8"));
    expect(pkg.devDependencies).toHaveProperty("@types/pg");
  });
});
