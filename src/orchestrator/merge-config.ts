import * as fs from "node:fs";
import * as path from "node:path";
import { getForemanHomePath } from "../lib/foreman-paths.js";

export interface MergeQueueConfig {
  tier2SafetyCheck: {
    maxDiscardedLines: number;
    maxDiscardedPercent: number;
  };
  costControls: {
    maxFileLines: number;
    maxSessionBudgetUsd: number;
  };
  syntaxCheckers: Record<string, string>;
  proseDetection: Record<string, string[]>;
  testAfterMerge: "ai-only" | "always" | "never";
}

export const DEFAULT_MERGE_CONFIG: MergeQueueConfig = {
  tier2SafetyCheck: {
    maxDiscardedLines: 20,
    maxDiscardedPercent: 30,
  },
  costControls: {
    maxFileLines: 1000,
    maxSessionBudgetUsd: 5.0,
  },
  syntaxCheckers: {
    ".ts": "tsc --noEmit",
    ".js": "node --check",
  },
  proseDetection: {
    ".ts": [
      "^import\\b",
      "^export\\b",
      "^const\\b",
      "^let\\b",
      "^var\\b",
      "^function\\b",
      "^class\\b",
      "^interface\\b",
      "^type\\b",
    ],
    ".js": [
      "^import\\b",
      "^export\\b",
      "^const\\b",
      "^let\\b",
      "^var\\b",
      "^function\\b",
      "^class\\b",
    ],
    ".py": ["^import\\b", "^from\\b", "^def\\b", "^class\\b", "^if\\b"],
    ".go": [
      "^package\\b",
      "^import\\b",
      "^func\\b",
      "^type\\b",
      "^var\\b",
    ],
  },
  testAfterMerge: "ai-only",
};

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Keys whose values are structured objects that should be deep-merged. */
const DEEP_MERGE_KEYS = new Set(["tier2SafetyCheck", "costControls"]);

function deepMerge(
  defaults: Record<string, unknown>,
  overrides: Record<string, unknown>,
  depth: number = 0,
): Record<string, unknown> {
  const result: Record<string, unknown> = { ...defaults };

  for (const key of Object.keys(overrides)) {
    const defaultVal = defaults[key];
    const overrideVal = overrides[key];

    // Only deep-merge known structured config objects at the top level.
    // Record<string, ...> types (syntaxCheckers, proseDetection) are replaced entirely.
    if (
      depth === 0 &&
      DEEP_MERGE_KEYS.has(key) &&
      isPlainObject(defaultVal) &&
      isPlainObject(overrideVal)
    ) {
      result[key] = deepMerge(defaultVal, overrideVal, depth + 1);
    } else {
      result[key] = overrideVal;
    }
  }

  return result;
}

export function loadMergeConfig(_projectPath: string): MergeQueueConfig {
  const configPath = getForemanHomePath("config.json");

  let fileContents: string;
  try {
    fileContents = fs.readFileSync(configPath, "utf-8");
  } catch {
    return { ...DEFAULT_MERGE_CONFIG };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(fileContents);
  } catch {
    console.warn(
      `Failed to parse ${configPath}: invalid JSON, using defaults`,
    );
    return { ...DEFAULT_MERGE_CONFIG };
  }

  if (!isPlainObject(parsed) || !isPlainObject(parsed["mergeQueue"])) {
    return { ...DEFAULT_MERGE_CONFIG };
  }

  const userConfig = parsed["mergeQueue"] as Record<string, unknown>;
  const merged = deepMerge(
    DEFAULT_MERGE_CONFIG as unknown as Record<string, unknown>,
    userConfig,
  );

  return merged as unknown as MergeQueueConfig;
}
