import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    exclude: [
      ".omx/**",
      "**/node_modules/**",
      "**/dist/**",
      "**/.omx/**",
      "**/.foreman-worktrees/**",
      "**/.claude/worktrees/**",
    ],
    testTimeout: 30000,
    hookTimeout: 30000,
    env: {
      // Prevent git from hanging on credential prompts during tests
      GIT_TERMINAL_PROMPT: "0",
      GIT_ASKPASS: "true",
    },
  },
});
