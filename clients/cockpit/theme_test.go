package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestThemeTokensDriveCockpitPalette(t *testing.T) {
	data, err := os.ReadFile("theme/tokens.yaml")
	if err != nil {
		t.Fatalf("read tokens: %v", err)
	}
	text := string(data)
	for name, value := range map[string]string{
		"primary":        themeTokenTextPrimary,
		"secondary":      themeTokenTextSecondary,
		"faint":          themeTokenTextFaint,
		"inverted":       themeTokenTextInverted,
		"accent":         themeTokenAccent,
		"accent2":        themeTokenAccent2,
		"success":        themeTokenSuccess,
		"warning":        themeTokenWarning,
		"danger":         themeTokenDanger,
		"borderFocus":    themeTokenBorderFocus,
		"borderBlur":     themeTokenBorderBlur,
		"selected":       themeTokenBgSelected,
		"emphasis":       themeTokenBgEmphasis,
		"bar":            themeTokenBgBar,
		"ghEnhanceTheme": themeTokenGhEnhanceTheme,
	} {
		if !strings.Contains(text, value) {
			t.Fatalf("token %s value %s missing from tokens.yaml", name, value)
		}
		if strings.HasPrefix(value, "#") && !regexp.MustCompile(`^#[0-9a-fA-F]{6}$`).MatchString(value) {
			t.Fatalf("token %s must be #RRGGBB, got %q", name, value)
		}
	}
	if cWhite != cText {
		t.Fatalf("cWhite must come from the text.primary token")
	}
}

func TestThemeProjectionFragmentsUseTokens(t *testing.T) {
	for _, path := range []string{"theme/gh-dash.yml", "theme/enhance.env", "theme/diffnav.yml", "theme/diffnav/config.yml", "theme/delta.gitconfig", "theme/glamour.json"} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("expected generated theme fragment %s: %v", path, err)
		}
	}
	dash, err := os.ReadFile("theme/gh-dash.yml")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(dash), themeTokenTextPrimary) || !strings.Contains(string(dash), themeTokenBgSelected) || !strings.Contains(string(dash), themeTokenDanger) {
		t.Fatalf("gh-dash theme does not include core tokens:\n%s", string(dash))
	}
	for _, want := range []string{"builtin: search", "builtin: down", "builtin: pageDown", "builtin: openGithub", "builtin: copyurl"} {
		if !strings.Contains(string(dash), want) {
			t.Fatalf("gh-dash theme missing keybinding %q:\n%s", want, string(dash))
		}
	}
	enhance, err := os.ReadFile("theme/enhance.env")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(enhance), "ENHANCE_THEME="+themeTokenGhEnhanceTheme) {
		t.Fatalf("gh enhance env does not include theme token:\n%s", string(enhance))
	}
	delta, err := os.ReadFile("theme/delta.gitconfig")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(delta), themeTokenDiffSyntaxTheme) || !strings.Contains(string(delta), themeTokenDiffAdd) || !strings.Contains(string(delta), themeTokenDiffRemove) {
		t.Fatalf("delta config does not include diff tokens:\n%s", string(delta))
	}
}

func TestInstallThemeFragmentsWritesAndBacksUpConfigs(t *testing.T) {
	configDir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", configDir)

	target := filepath.Join(configDir, "gh-dash", "config.yml")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("user: config\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if err := installThemeFragments(&out); err != nil {
		t.Fatal(err)
	}
	installed, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	source, err := os.ReadFile("theme/gh-dash.yml")
	if err != nil {
		t.Fatal(err)
	}
	if string(installed) != string(source) {
		t.Fatalf("expected gh-dash config to match generated fragment")
	}
	backup, err := os.ReadFile(target + ".bak")
	if err != nil {
		t.Fatal(err)
	}
	if string(backup) != "user: config\n" {
		t.Fatalf("expected previous config backup, got %q", string(backup))
	}
	if !strings.Contains(out.String(), "delta fragment installed") {
		t.Fatalf("expected delta include guidance, got %q", out.String())
	}
}
