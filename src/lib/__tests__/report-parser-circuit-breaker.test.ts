import { describe, expect, it } from "vitest";
import { diffQAFailures, parseQAFailures } from "../report-parser.js";

const failingReport = `# QA

## Verdict: FAIL

### Typecheck
**File:** src/app.ts
**Command:** npx tsc --noEmit
**Failure Output:** TS2322 persists
**Requested Fix:** Fix type mismatch
`;

describe("same-failure retry signatures", () => {
  it("marks repeated failure signatures as still_failing", () => {
    const first = parseQAFailures(failingReport).items;
    const second = parseQAFailures(failingReport).items;

    expect(diffQAFailures(first, second)).toEqual([
      expect.objectContaining({
        category: "Typecheck",
        file: "src/app.ts",
        command: "npx tsc --noEmit",
        status: "still_failing",
      }),
    ]);
  });

  it("keeps category|file|command stable for circuit breaker matching", () => {
    const [item] = parseQAFailures(failingReport).items;
    expect(`${item!.category}|${item!.file ?? ""}|${item!.command ?? ""}`).toBe(
      "Typecheck|src/app.ts|npx tsc --noEmit",
    );
  });
});
