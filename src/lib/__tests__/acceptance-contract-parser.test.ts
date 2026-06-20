import { describe, expect, it } from "vitest";
import { parseAcceptanceContract, validateAcceptanceCoverage } from "../report-parser.js";

describe("acceptance contract parser", () => {
  const explorer = `# Explorer\n\n## Acceptance Contract\n- AC1: CLI command is registered and documented.\n- [ ] Focused regression tests cover the parser.\n- Typecheck passes with \`npx tsc --noEmit\`.\n\n## Developer Handoff\nEdit files.\n`;

  it("parses criteria from EXPLORER_REPORT.md", () => {
    expect(parseAcceptanceContract(explorer)).toEqual([
      { id: "AC1", text: "CLI command is registered and documented." },
      { id: "AC2", text: "Focused regression tests cover the parser." },
      { id: "AC3", text: "Typecheck passes with npx tsc --noEmit." },
    ]);
  });

  it("requires phase reports to carry and address all criteria", () => {
    const phaseReport = `# QA\n\n## Verdict: PASS\n\n## Acceptance Contract\n- AC1: CLI command is registered and documented — verified.\n- AC2: Focused regression tests cover the parser — verified.\n- AC3: Typecheck passes with npx tsc --noEmit — verified.\n`;
    expect(validateAcceptanceCoverage(explorer, phaseReport)).toMatchObject({ ok: true, missing: [] });
  });

  it("reports missing criteria", () => {
    const phaseReport = `# QA\n\n## Verdict: PASS\n\n## Acceptance Contract\n- AC1: CLI command is registered and documented — verified.\n`;
    const result = validateAcceptanceCoverage(explorer, phaseReport);
    expect(result.ok).toBe(false);
    expect(result.missing.map((criterion) => criterion.id)).toEqual(["AC2", "AC3"]);
  });
});
