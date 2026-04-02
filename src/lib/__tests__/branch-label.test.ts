import { describe, it, expect } from "vitest";
import {
  extractBranchLabel,
  isDefaultBranch,
  applyBranchLabel,
  isValidBranchLabel,
  normalizeBranchLabel,
} from "../branch-label.js";

describe("normalizeBranchLabel", () => {
  it("strips trailing jujutsu display markers", () => {
    expect(normalizeBranchLabel("dev*")).toBe("dev");
    expect(normalizeBranchLabel("feature/test***")).toBe("feature/test");
  });
});

describe("isValidBranchLabel", () => {
  it("returns false for undefined and empty values", () => {
    expect(isValidBranchLabel(undefined)).toBe(false);
    expect(isValidBranchLabel("")).toBe(false);
    expect(isValidBranchLabel("   ")).toBe(false);
  });

  it("returns false for detached HEAD", () => {
    expect(isValidBranchLabel("HEAD")).toBe(false);
  });

  it("returns true for real branch names", () => {
    expect(isValidBranchLabel("installer")).toBe(true);
    expect(isValidBranchLabel("feature/my-feature")).toBe(true);
    expect(isValidBranchLabel("dev*")).toBe(true);
  });
});

describe("extractBranchLabel", () => {
  it("returns undefined when labels is undefined", () => {
    expect(extractBranchLabel(undefined)).toBeUndefined();
  });

  it("returns undefined when labels is empty", () => {
    expect(extractBranchLabel([])).toBeUndefined();
  });

  it("returns undefined when no branch: label exists", () => {
    expect(extractBranchLabel(["workflow:smoke", "priority:high"])).toBeUndefined();
  });

  it("extracts simple branch name", () => {
    expect(extractBranchLabel(["branch:installer"])).toBe("installer");
  });

  it("extracts branch with slashes", () => {
    expect(extractBranchLabel(["branch:feature/my-feature"])).toBe("feature/my-feature");
  });

  it("returns first branch: label when multiple exist", () => {
    expect(extractBranchLabel(["branch:main", "branch:installer"])).toBe("main");
  });

  it("ignores non-branch labels", () => {
    expect(extractBranchLabel(["workflow:smoke", "branch:installer", "priority:low"])).toBe(
      "installer",
    );
  });

  it("returns undefined for branch: with empty value", () => {
    expect(extractBranchLabel(["branch:"])).toBeUndefined();
  });

  it("returns undefined for branch:HEAD", () => {
    expect(extractBranchLabel(["branch:HEAD"])).toBeUndefined();
  });

  it("normalizes decorated jujutsu branch labels", () => {
    expect(extractBranchLabel(["branch:dev*"])).toBe("dev");
  });
});

describe("isDefaultBranch", () => {
  it("returns true for exact match with default branch", () => {
    expect(isDefaultBranch("main", "main")).toBe(true);
  });

  it("returns true for 'master'", () => {
    expect(isDefaultBranch("master", "dev")).toBe(true);
  });

  it("returns true for 'dev'", () => {
    expect(isDefaultBranch("dev", "main")).toBe(true);
  });

  it("treats decorated current branch names as the same default branch", () => {
    expect(isDefaultBranch("dev*", "dev")).toBe(true);
  });

  it("returns true for 'develop'", () => {
    expect(isDefaultBranch("develop", "main")).toBe(true);
  });

  it("returns true for 'trunk'", () => {
    expect(isDefaultBranch("trunk", "main")).toBe(true);
  });

  it("returns false for feature branch", () => {
    expect(isDefaultBranch("installer", "main")).toBe(false);
  });

  it("returns false for feature branch with slashes", () => {
    expect(isDefaultBranch("feature/my-feature", "main")).toBe(false);
  });
});

describe("applyBranchLabel", () => {
  it("adds branch: label to empty array", () => {
    expect(applyBranchLabel([], "installer")).toEqual(["branch:installer"]);
  });

  it("adds branch: label to undefined labels", () => {
    expect(applyBranchLabel(undefined, "installer")).toEqual(["branch:installer"]);
  });

  it("adds branch: label alongside other labels", () => {
    const result = applyBranchLabel(["workflow:smoke"], "installer");
    expect(result).toContain("workflow:smoke");
    expect(result).toContain("branch:installer");
  });

  it("replaces existing branch: label", () => {
    const result = applyBranchLabel(["branch:old-branch", "workflow:smoke"], "installer");
    expect(result).not.toContain("branch:old-branch");
    expect(result).toContain("branch:installer");
    expect(result).toContain("workflow:smoke");
  });

  it("replaces multiple existing branch: labels", () => {
    const result = applyBranchLabel(["branch:a", "branch:b"], "installer");
    const branchLabels = result.filter((l) => l.startsWith("branch:"));
    expect(branchLabels).toHaveLength(1);
    expect(branchLabels[0]).toBe("branch:installer");
  });

  it("drops invalid branch labels like HEAD", () => {
    expect(applyBranchLabel(["workflow:smoke", "branch:old"], "HEAD")).toEqual(["workflow:smoke"]);
  });
});
