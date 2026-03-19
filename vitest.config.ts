import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    exclude: [
      "**/node_modules/**",
      "**/dist/**",
      "**/.foreman-worktrees/**",
      "**/.claude/worktrees/**",
    ],
    testTimeout: 30000,
  },
});
