package main

import (
	"os"
	"os/exec"
	"path/filepath"
)

func cockpitThemePath(parts ...string) string {
	candidates := []string{}
	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates, filepath.Join(append([]string{wd, "theme"}, parts...)...))
	}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(append([]string{filepath.Dir(exe), "theme"}, parts...)...))
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			if abs, err := filepath.Abs(candidate); err == nil {
				return abs
			}
			return candidate
		}
	}
	if len(candidates) == 0 {
		return filepath.Join(append([]string{"theme"}, parts...)...)
	}
	if abs, err := filepath.Abs(candidates[0]); err == nil {
		return abs
	}
	return candidates[0]
}

func appendCmdEnv(cmd *exec.Cmd, kv ...string) {
	cmd.Env = append(os.Environ(), kv...)
}
