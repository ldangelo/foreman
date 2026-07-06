import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { z } from "zod";
import { extractStructuredOutput, getPiSdkEventError, getSandboxedPiResourcePaths, isDangerousBashCommand, normalizeLegacySlashPrompt, shouldSandboxPiExtensions, type StreamEvent } from "../pi-sdk-runner.js";

const tmpDirs: string[] = [];

afterEach(() => {
  for (const dir of tmpDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("isDangerousBashCommand", () => {
  it("blocks worker attempts to kill Foreman or unrelated processes", () => {
    expect(isDangerousBashCommand("lsof -ti:4766 | xargs kill -9")).toBe(true);
    expect(isDangerousBashCommand("pkill -f foreman_server")).toBe(true);
    expect(isDangerousBashCommand("foreman server stop")).toBe(true);
  });

  it("allows normal task-local validation commands", () => {
    expect(isDangerousBashCommand("npm test -- --runInBand")).toBe(false);
    expect(isDangerousBashCommand("mix test test/projection_store_test.exs")).toBe(false);
  });
});

describe("shouldSandboxPiExtensions", () => {
  it("defaults Foreman Pi SDK sessions to extension sandboxing", () => {
    expect(shouldSandboxPiExtensions({})).toBe(true);
  });

  it("allows opting back into user Pi extensions", () => {
    expect(shouldSandboxPiExtensions({ FOREMAN_PI_EXTENSIONS: "user" })).toBe(false);
  });
});

describe("normalizeLegacySlashPrompt", () => {
  it("maps namespaced legacy slash commands to Pi prompt templates", () => {
    expect(normalizeLegacySlashPrompt("/ensemble:create-prd Build inbox")).toBe("/ensemble-create-prd Build inbox");
  });

  it("preserves native /skill:name invocations", () => {
    expect(normalizeLegacySlashPrompt("/skill:ensemble-create-prd Build inbox")).toBe("/skill:ensemble-create-prd Build inbox");
  });

  it("leaves non-command prompts unchanged", () => {
    expect(normalizeLegacySlashPrompt("Please fix this")).toBe("Please fix this");
  });
});

describe("getPiSdkEventError", () => {
  it("treats SDK stopReason=error events as failures", () => {
    expect(getPiSdkEventError({
      type: "turn_end",
      stopReason: "error",
      errorMessage: "provider usage exhausted",
    } as never)).toBe("provider usage exhausted");
  });

  it("treats SDK errorMessage-only events as failures", () => {
    expect(getPiSdkEventError({
      type: "message_end",
      errorMessage: "provider failed",
    } as never)).toBe("provider failed");
  });
});

describe("getSandboxedPiResourcePaths", () => {
  it("allows only Ensemble resources plus Foreman send-mail skill", () => {
    const ensemblePiRoot = mkdtempSync(join(tmpdir(), "foreman-ensemble-pi-"));
    tmpDirs.push(ensemblePiRoot);
    mkdirSync(join(ensemblePiRoot, "extensions"));
    mkdirSync(join(ensemblePiRoot, "skills"));
    mkdirSync(join(ensemblePiRoot, "prompts"));

    const resources = getSandboxedPiResourcePaths({ FOREMAN_ENSEMBLE_PI_PATH: ensemblePiRoot });

    expect(resources.extensionPaths).toEqual([join(ensemblePiRoot, "extensions")]);
    expect(resources.skillPaths).toContain(join(ensemblePiRoot, "skills"));
    expect(resources.skillPaths.some((path) => path.endsWith("send-mail/SKILL.md"))).toBe(true);
    expect(resources.promptTemplatePaths).toEqual([join(ensemblePiRoot, "prompts")]);
  });
});

describe("StreamEvent type", () => {
  it("accepts valid text event structure", () => {
    const event: StreamEvent = {
      type: "text",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      delta: "Hello",
    };
    expect(event.type).toBe("text");
    expect(event.delta).toBe("Hello");
  });

  it("accepts valid toolCall event structure", () => {
    const event: StreamEvent = {
      type: "toolCall",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      toolName: "Read",
      args: { path: "/tmp/test.txt" },
    };
    expect(event.type).toBe("toolCall");
    expect(event.toolName).toBe("Read");
    expect(event.args).toEqual({ path: "/tmp/test.txt" });
  });

  it("accepts valid turnStart event structure", () => {
    const event: StreamEvent = {
      type: "turnStart",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
    };
    expect(event.type).toBe("turnStart");
    expect(event.iteration).toBe(1);
  });

  it("accepts valid turnEnd event structure with token info", () => {
    const event: StreamEvent = {
      type: "turnEnd",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      tokensIn: 100,
      tokensOut: 200,
    };
    expect(event.type).toBe("turnEnd");
    expect(event.tokensIn).toBe(100);
    expect(event.tokensOut).toBe(200);
  });

  it("accepts valid turnEnd event structure without token info", () => {
    const event: StreamEvent = {
      type: "turnEnd",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
    };
    expect(event.type).toBe("turnEnd");
    expect(event.tokensIn).toBeUndefined();
  });

  it("accepts valid agentEnd event structure", () => {
    const event: StreamEvent = {
      type: "agentEnd",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      success: true,
      message: "Done",
    };
    expect(event.type).toBe("agentEnd");
    expect(event.success).toBe(true);
    expect(event.message).toBe("Done");
  });

  it("accepts agentEnd event with success=false", () => {
    const event: StreamEvent = {
      type: "agentEnd",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      success: false,
      message: "Agent encountered an error",
    };
    expect(event.type).toBe("agentEnd");
    expect(event.success).toBe(false);
  });
});

describe("extractStructuredOutput", () => {
  const schema = z.object({
    summary: z.string(),
    score: z.number(),
  });

  it("extracts valid JSON from tag and validates against schema", () => {
    const outputText = "Some text before <result>{\"summary\":\"Test\",\"score\":42}</result> some text after";
    const result = extractStructuredOutput(outputText, { tag: "result", schema });
    expect(result.output).toEqual({ summary: "Test", score: 42 });
    expect(result.error).toBeUndefined();
  });

  it("handles nested objects in JSON", () => {
    const outputText = "<data>{\"name\":\"test\",\"metadata\":{\"tags\":[\"a\",\"b\"]}}</data>";
    const nestedSchema = z.object({
      name: z.string(),
      metadata: z.object({
        tags: z.array(z.string()),
      }),
    });
    const result = extractStructuredOutput(outputText, { tag: "data", schema: nestedSchema });
    expect(result.output).toEqual({ name: "test", metadata: { tags: ["a", "b"] } });
  });

  it("returns error when tag is not found", () => {
    const outputText = "No result tag here";
    const result = extractStructuredOutput(outputText, { tag: "result", schema });
    expect(result.output).toBeUndefined();
    expect(result.error).toBe("Tag <result> not found in output");
  });

  it("returns error when content inside tag is empty", () => {
    const outputText = "<result></result>";
    const result = extractStructuredOutput(outputText, { tag: "result", schema });
    expect(result.output).toBeUndefined();
    expect(result.error).toBe("Empty content inside <result> tag");
  });

  it("returns error when content is not valid JSON", () => {
    const outputText = "<result>not valid json</result>";
    const result = extractStructuredOutput(outputText, { tag: "result", schema });
    expect(result.output).toBeUndefined();
    expect(result.error).toContain("Invalid JSON inside <result>");
  });

  it("returns error when JSON fails schema validation", () => {
    const outputText = "<result>{\"summary\":\"test\",\"score\":\"not a number\"}</result>";
    const result = extractStructuredOutput(outputText, { tag: "result", schema });
    expect(result.output).toBeUndefined();
    expect(result.error).toContain("Schema validation failed for <result>");
  });

  it("handles multiline JSON content", () => {
    const outputText = `<result>{
  "summary": "Multiline",
  "score": 100
}</result>`;
    const result = extractStructuredOutput(outputText, { tag: "result", schema });
    expect(result.output).toEqual({ summary: "Multiline", score: 100 });
  });

  it("handles whitespace around JSON content", () => {
    const outputText = "<result>   {\"summary\":\"trimmed\",\"score\":5}   </result>";
    const result = extractStructuredOutput(outputText, { tag: "result", schema });
    expect(result.output).toEqual({ summary: "trimmed", score: 5 });
  });

  it("returns error when outputText is undefined", () => {
    const result = extractStructuredOutput(undefined, { tag: "result", schema });
    expect(result.output).toBeUndefined();
    expect(result.error).toBe("No output text to extract from");
  });

  it("returns error when outputText is empty string", () => {
    const result = extractStructuredOutput("", { tag: "result", schema });
    expect(result.output).toBeUndefined();
    expect(result.error).toBe("No output text to extract from");
  });

  it("is case-insensitive for tag matching", () => {
    const outputText = "<RESULT>{\"summary\":\"Case test\",\"score\":1}</RESULT>";
    const result = extractStructuredOutput(outputText, { tag: "result", schema });
    expect(result.output).toEqual({ summary: "Case test", score: 1 });
  });

  it("handles special characters in tag name (escaped properly)", () => {
    const outputText = "<custom-tag>{\"summary\":\"special\",\"score\":9}</custom-tag>";
    const result = extractStructuredOutput(outputText, { tag: "custom-tag", schema });
    expect(result.output).toEqual({ summary: "special", score: 9 });
  });

  it("handles tag with dot (regex metacharacter)", () => {
    const outputText = "<result.data>{\"summary\":\"dot test\",\"score\":1}</result.data>";
    const result = extractStructuredOutput(outputText, { tag: "result.data", schema });
    expect(result.output).toEqual({ summary: "dot test", score: 1 });
  });

  it("handles tag with plus (regex metacharacter)", () => {
    const outputText = "<tag+name>{\"summary\":\"plus test\",\"score\":2}</tag+name>";
    const result = extractStructuredOutput(outputText, { tag: "tag+name", schema });
    expect(result.output).toEqual({ summary: "plus test", score: 2 });
  });

  it("handles tag with question mark (regex metacharacter)", () => {
    const outputText = "<tag?name>{\"summary\":\"question test\",\"score\":3}</tag?name>";
    const result = extractStructuredOutput(outputText, { tag: "tag?name", schema });
    expect(result.output).toEqual({ summary: "question test", score: 3 });
  });

  it("handles tag with caret (regex metacharacter)", () => {
    const outputText = "<tag^name>{\"summary\":\"caret test\",\"score\":4}</tag^name>";
    const result = extractStructuredOutput(outputText, { tag: "tag^name", schema });
    expect(result.output).toEqual({ summary: "caret test", score: 4 });
  });

  it("handles tag with dollar sign (regex metacharacter)", () => {
    const outputText = "<tag$name>{\"summary\":\"dollar test\",\"score\":5}</tag$name>";
    const result = extractStructuredOutput(outputText, { tag: "tag$name", schema });
    expect(result.output).toEqual({ summary: "dollar test", score: 5 });
  });

  it("handles tag with asterisk (regex metacharacter)", () => {
    const outputText = "<tag*name>{\"summary\":\"asterisk test\",\"score\":6}</tag*name>";
    const result = extractStructuredOutput(outputText, { tag: "tag*name", schema });
    expect(result.output).toEqual({ summary: "asterisk test", score: 6 });
  });
});
