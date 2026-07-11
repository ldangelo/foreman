package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type themeInstallTarget struct {
	Name   string
	Source string
	Target string
}

func installThemeFragments(w io.Writer) error {
	for _, target := range themeInstallTargets() {
		if err := installThemeFragment(target); err != nil {
			return err
		}
		fmt.Fprintf(w, "installed %s -> %s\n", target.Name, target.Target)
	}
	fmt.Fprintln(w, "delta fragment installed; include it from your git config if desired")
	return nil
}

func themeInstallTargets() []themeInstallTarget {
	cfg := configHome()
	return []themeInstallTarget{
		{Name: "gh-dash", Source: cockpitThemePath("gh-dash.yml"), Target: filepath.Join(cfg, "gh-dash", "config.yml")},
		{Name: "diffnav", Source: cockpitThemePath("diffnav", "config.yml"), Target: filepath.Join(cfg, "diffnav", "config.yml")},
		{Name: "gh-enhance", Source: cockpitThemePath("enhance.env"), Target: filepath.Join(cfg, "foreman-cockpit", "enhance.env")},
		{Name: "delta", Source: cockpitThemePath("delta.gitconfig"), Target: filepath.Join(cfg, "foreman-cockpit", "delta.gitconfig")},
		{Name: "glamour", Source: cockpitThemePath("glamour.json"), Target: filepath.Join(cfg, "foreman-cockpit", "glamour.json")},
	}
}

func installThemeFragment(target themeInstallTarget) error {
	content, err := os.ReadFile(target.Source)
	if err != nil {
		return fmt.Errorf("read %s theme fragment: %w", target.Name, err)
	}
	if existing, err := os.ReadFile(target.Target); err == nil {
		if string(existing) == string(content) {
			return nil
		}
		backup := target.Target + ".bak"
		if err := os.WriteFile(backup, existing, 0o600); err != nil {
			return fmt.Errorf("backup %s theme config: %w", target.Name, err)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("read existing %s theme config: %w", target.Name, err)
	}
	if err := os.MkdirAll(filepath.Dir(target.Target), 0o755); err != nil {
		return fmt.Errorf("create %s theme config dir: %w", target.Name, err)
	}
	if err := os.WriteFile(target.Target, content, 0o600); err != nil {
		return fmt.Errorf("write %s theme config: %w", target.Name, err)
	}
	return nil
}

func configHome() string {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return xdg
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".config")
	}
	return ".config"
}

func installThemesRequested(args []string) bool {
	for _, arg := range args {
		if arg == "--install-themes" {
			return true
		}
	}
	return false
}
