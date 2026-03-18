import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  loadTemplate,
  interpolateTemplate,
  loadAndInterpolate,
  clearTemplateCache,
} from "../template-loader.js";

describe("interpolateTemplate", () => {
  it("replaces a single placeholder", () => {
    expect(interpolateTemplate("Hello {{name}}", { name: "World" })).toBe("Hello World");
  });

  it("replaces multiple placeholders", () => {
    const result = interpolateTemplate("{{a}} and {{b}}", { a: "foo", b: "bar" });
    expect(result).toBe("foo and bar");
  });

  it("replaces the same placeholder multiple times", () => {
    const result = interpolateTemplate("{{x}}/{{x}}", { x: "seed-1" });
    expect(result).toBe("seed-1/seed-1");
  });

  it("leaves unknown placeholders as-is", () => {
    const result = interpolateTemplate("{{known}} {{unknown}}", { known: "yes" });
    expect(result).toBe("yes {{unknown}}");
  });

  it("handles empty variables map", () => {
    const result = interpolateTemplate("{{foo}}", {});
    expect(result).toBe("{{foo}}");
  });

  it("handles template with no placeholders", () => {
    expect(interpolateTemplate("plain text", {})).toBe("plain text");
  });

  it("handles empty template", () => {
    expect(interpolateTemplate("", { foo: "bar" })).toBe("");
  });
});

describe("loadTemplate", () => {
  beforeEach(() => clearTemplateCache());
  afterEach(() => clearTemplateCache());

  it("loads explorer-prompt.md", () => {
    const content = loadTemplate("explorer-prompt.md");
    expect(content).toContain("Explorer");
    expect(content).toContain("{{seedId}}");
  });

  it("loads developer-prompt.md", () => {
    const content = loadTemplate("developer-prompt.md");
    expect(content).toContain("Developer");
    expect(content).toContain("{{seedId}}");
  });

  it("loads qa-prompt.md", () => {
    const content = loadTemplate("qa-prompt.md");
    expect(content).toContain("QA");
    expect(content).toContain("{{seedId}}");
  });

  it("loads reviewer-prompt.md", () => {
    const content = loadTemplate("reviewer-prompt.md");
    expect(content).toContain("Reviewer");
    expect(content).toContain("{{seedId}}");
  });

  it("loads sentinel-prompt.md", () => {
    const content = loadTemplate("sentinel-prompt.md");
    expect(content).toContain("Sentinel");
    expect(content).toContain("{{branch}}");
  });

  it("loads lead-prompt.md", () => {
    const content = loadTemplate("lead-prompt.md");
    expect(content).toContain("Engineering Lead");
    expect(content).toContain("{{seedId}}");
  });

  it("throws a meaningful error for missing template", () => {
    expect(() => loadTemplate("nonexistent-template.md")).toThrow(
      /Failed to load template "nonexistent-template.md"/,
    );
  });

  it("rejects filenames containing a forward slash", () => {
    expect(() => loadTemplate("../secrets.md")).toThrow(
      /loadTemplate expects a bare filename/,
    );
  });

  it("rejects filenames containing a backslash", () => {
    expect(() => loadTemplate("..\\secrets.md")).toThrow(
      /loadTemplate expects a bare filename/,
    );
  });

  it("caches the template on second load", () => {
    // Load twice — should not throw and should return the same content
    const first = loadTemplate("explorer-prompt.md");
    const second = loadTemplate("explorer-prompt.md");
    expect(first).toBe(second);
  });

  it("clearTemplateCache allows re-reading from disk", () => {
    const first = loadTemplate("explorer-prompt.md");
    clearTemplateCache();
    const second = loadTemplate("explorer-prompt.md");
    expect(first).toBe(second);
  });
});

describe("loadAndInterpolate", () => {
  beforeEach(() => clearTemplateCache());
  afterEach(() => clearTemplateCache());

  it("loads and interpolates explorer-prompt.md", () => {
    const result = loadAndInterpolate("explorer-prompt.md", {
      seedId: "bd-test",
      seedTitle: "Test feature",
      seedDescription: "A test description",
    });
    expect(result).toContain("bd-test");
    expect(result).toContain("Test feature");
    expect(result).toContain("A test description");
    expect(result).not.toContain("{{seedId}}");
    expect(result).not.toContain("{{seedTitle}}");
  });
});
