package main

import (
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Editor       EditorConfig  `yaml:"editor"`
	Integrations Integrations  `yaml:"integrations"`
	PR           PRConfig      `yaml:"pr"`
	Cockpit      CockpitConfig `yaml:"cockpit"`
}

type Integrations struct {
	Diffnav   DiffnavConfig   `yaml:"diffnav"`
	Delta     DeltaConfig     `yaml:"delta"`
	GhDash    GhDashConfig    `yaml:"ghDash"`
	GhEnhance GhEnhanceConfig `yaml:"ghEnhance"`
	Omp       OmpConfig       `yaml:"omp"`
}

type DiffnavConfig struct {
	Enable string `yaml:"enable"`
	Base   string `yaml:"base"`
	Watch  bool   `yaml:"watch"`
}

type DeltaConfig struct {
	Enable string `yaml:"enable"`
}

type GhDashConfig struct {
	Enable string   `yaml:"enable"`
	Args   []string `yaml:"args"`
}

type GhEnhanceConfig struct {
	Enable string   `yaml:"enable"`
	Args   []string `yaml:"args"`
}

type OmpConfig struct {
	Enable    string     `yaml:"enable"`
	Cmd       string     `yaml:"cmd"`
	Mode      string     `yaml:"mode"`
	Tmux      TmuxConfig `yaml:"tmux"`
	KeepShell bool       `yaml:"keepShell"`
	Session   string     `yaml:"session"`
	Args      []string   `yaml:"args"`
}

type TmuxConfig struct {
	Split string `yaml:"split"`
}

type PRConfig struct {
	Provider string `yaml:"provider"`
}

type CockpitConfig struct {
	ExportDir string `yaml:"exportDir"`
}

func defaultConfig() Config {
	return Config{
		Editor: defaultEditorConfig(),
		Integrations: Integrations{
			Diffnav:   DiffnavConfig{Enable: "auto", Base: "origin/dev"},
			Delta:     DeltaConfig{Enable: "auto"},
			GhDash:    GhDashConfig{Enable: "auto"},
			GhEnhance: GhEnhanceConfig{Enable: "auto"},
			Omp:       OmpConfig{Enable: "auto", Cmd: "omp", Mode: "auto", Tmux: TmuxConfig{Split: "horizontal"}, KeepShell: true, Session: "per-task"},
		},
		PR:      PRConfig{Provider: "github"},
		Cockpit: CockpitConfig{ExportDir: defaultCockpitExportDir()},
	}
}

func loadConfig(path string) (Config, error) {
	cfg := defaultConfig()
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			applyConfigEnv(&cfg)
			return cfg, nil
		}
		applyConfigEnv(&cfg)
		return cfg, err
	}
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		applyConfigEnv(&cfg)
		return cfg, err
	}
	cfg.normalize()
	applyConfigEnv(&cfg)
	return cfg, nil
}

func (c *Config) normalize() {
	defaults := defaultConfig()
	if c.Editor.Cmd == "" {
		c.Editor.Cmd = defaults.Editor.Cmd
	}
	if c.Editor.Mode == "" {
		c.Editor.Mode = defaults.Editor.Mode
	}
	c.Integrations.Diffnav.Enable = normalizeEnable(c.Integrations.Diffnav.Enable)
	if c.Integrations.Diffnav.Base == "" {
		c.Integrations.Diffnav.Base = defaults.Integrations.Diffnav.Base
	}
	c.Integrations.Delta.Enable = normalizeEnable(c.Integrations.Delta.Enable)
	c.Integrations.GhDash.Enable = normalizeEnable(c.Integrations.GhDash.Enable)
	c.Integrations.GhEnhance.Enable = normalizeEnable(c.Integrations.GhEnhance.Enable)
	c.Integrations.Omp.Enable = normalizeEnable(c.Integrations.Omp.Enable)
	if c.Integrations.Omp.Cmd == "" {
		c.Integrations.Omp.Cmd = defaults.Integrations.Omp.Cmd
	}
	c.Integrations.Omp.Mode = normalizeOmpMode(c.Integrations.Omp.Mode)
	if c.Integrations.Omp.Tmux.Split == "" {
		c.Integrations.Omp.Tmux.Split = defaults.Integrations.Omp.Tmux.Split
	}
	c.Integrations.Omp.Tmux.Split = normalizeTmuxSplit(c.Integrations.Omp.Tmux.Split)
	if c.Integrations.Omp.Session == "" {
		c.Integrations.Omp.Session = defaults.Integrations.Omp.Session
	}
	c.Integrations.Omp.Session = normalizeOmpSession(c.Integrations.Omp.Session)
	if c.PR.Provider == "" {
		c.PR.Provider = defaults.PR.Provider
	}
	if c.Cockpit.ExportDir == "" {
		c.Cockpit.ExportDir = defaults.Cockpit.ExportDir
	}
	c.Cockpit.ExportDir = expandHome(c.Cockpit.ExportDir)
}

func defaultCockpitExportDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ".foreman/cockpit-exports"
	}
	return filepath.Join(home, ".foreman", "cockpit-exports")
}

func normalizeEnable(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "on", "off", "auto":
		return strings.ToLower(strings.TrimSpace(v))
	case "":
		return "auto"
	default:
		return "auto"
	}
}

func normalizeOmpMode(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "auto", "tmux", "inline", "window":
		return strings.ToLower(strings.TrimSpace(v))
	case "":
		return "auto"
	default:
		return "auto"
	}
}

func normalizeTmuxSplit(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "horizontal", "vertical", "window":
		return strings.ToLower(strings.TrimSpace(v))
	case "":
		return "horizontal"
	default:
		return "horizontal"
	}
}

func normalizeOmpSession(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "per-task", "none":
		return strings.ToLower(strings.TrimSpace(v))
	case "":
		return "per-task"
	default:
		return "per-task"
	}
}

func applyConfigEnv(c *Config) {
	if v := os.Getenv("COCKPIT_DIFFNAV"); v != "" {
		c.Integrations.Diffnav.Enable = normalizeEnable(v)
	}
	if v := os.Getenv("COCKPIT_DELTA"); v != "" {
		c.Integrations.Delta.Enable = normalizeEnable(v)
	}
	if v := os.Getenv("COCKPIT_GHDASH"); v != "" {
		c.Integrations.GhDash.Enable = normalizeEnable(v)
	}
	if v := os.Getenv("COCKPIT_GHENHANCE"); v != "" {
		c.Integrations.GhEnhance.Enable = normalizeEnable(v)
	}
	if v := os.Getenv("COCKPIT_OMP"); v != "" {
		c.Integrations.Omp.Enable = normalizeEnable(v)
	}
	if v := os.Getenv("COCKPIT_OMP_MODE"); v != "" {
		c.Integrations.Omp.Mode = normalizeOmpMode(v)
	}
	if v := os.Getenv("COCKPIT_EXPORT_DIR"); v != "" {
		c.Cockpit.ExportDir = expandHome(v)
	}
}
