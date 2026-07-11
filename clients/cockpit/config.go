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


type CockpitConfig struct {
	ExportDir     string         `yaml:"exportDir"`
	Focus         FocusConfig    `yaml:"focus"`
	ReducedMotion bool           `yaml:"reducedMotion"`
	TaskList      TaskListConfig `yaml:"taskList"`
}

type TaskListConfig struct {
	Width    string        `yaml:"width"`
	Sections []TaskSection `yaml:"sections"`
}

type FocusConfig struct {
	DimInactive bool   `yaml:"dimInactive"`
	Style       string `yaml:"style"`
}

const (
	focusStyleBoth   = "both"
	focusStyleBorder = "border"
	focusStyleDim    = "dim"
)

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
		Cockpit: CockpitConfig{
			ExportDir: defaultCockpitExportDir(),
			Focus:     FocusConfig{DimInactive: true, Style: focusStyleBoth},
			TaskList:  TaskListConfig{Width: "auto", Sections: defaultTaskListSections()},
		},
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
	if c.Cockpit.ExportDir == "" {
		c.Cockpit.ExportDir = defaults.Cockpit.ExportDir
	}
	c.Cockpit.ExportDir = expandHome(c.Cockpit.ExportDir)
	c.Cockpit.Focus.Style = normalizeFocusStyle(c.Cockpit.Focus.Style)
	c.Cockpit.ReducedMotion = normalizeBool("", c.Cockpit.ReducedMotion)
	if c.Cockpit.TaskList.Width == "" {
		c.Cockpit.TaskList.Width = defaults.Cockpit.TaskList.Width
	}
	if len(c.Cockpit.TaskList.Sections) == 0 {
		c.Cockpit.TaskList.Sections = defaultTaskListSections()
	} else {
		c.Cockpit.TaskList.Sections = normalizeTaskSections(c.Cockpit.TaskList.Sections)
	}
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

func normalizeFocusStyle(v string) string {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case focusStyleBoth, focusStyleBorder, focusStyleDim:
		return strings.ToLower(strings.TrimSpace(v))
	case "":
		return focusStyleBoth
	default:
		return focusStyleBoth
	}
}

func normalizeBool(v string, fallback bool) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
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
	if v := os.Getenv("COCKPIT_FOCUS_STYLE"); v != "" {
		c.Cockpit.Focus.Style = normalizeFocusStyle(v)
	}
	if v := os.Getenv("COCKPIT_FOCUS_DIM_INACTIVE"); v != "" {
		c.Cockpit.Focus.DimInactive = normalizeBool(v, c.Cockpit.Focus.DimInactive)
	}
	if v := os.Getenv("COCKPIT_REDUCED_MOTION"); v != "" {
		c.Cockpit.ReducedMotion = normalizeBool(v, c.Cockpit.ReducedMotion)
	}
}
