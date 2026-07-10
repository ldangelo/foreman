package main

import (
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Editor       EditorConfig `yaml:"editor"`
	Integrations Integrations `yaml:"integrations"`
	PR           PRConfig     `yaml:"pr"`
}

type Integrations struct {
	Diffnav   DiffnavConfig   `yaml:"diffnav"`
	Delta     DeltaConfig     `yaml:"delta"`
	GhDash    GhDashConfig    `yaml:"ghDash"`
	GhEnhance GhEnhanceConfig `yaml:"ghEnhance"`
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

type PRConfig struct {
	Provider string `yaml:"provider"`
}

func defaultConfig() Config {
	return Config{
		Editor: defaultEditorConfig(),
		Integrations: Integrations{
			Diffnav:   DiffnavConfig{Enable: "auto", Base: "origin/dev"},
			Delta:     DeltaConfig{Enable: "auto"},
			GhDash:    GhDashConfig{Enable: "auto"},
			GhEnhance: GhEnhanceConfig{Enable: "auto"},
		},
		PR: PRConfig{Provider: "github"},
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
	if c.PR.Provider == "" {
		c.PR.Provider = defaults.PR.Provider
	}
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
}
