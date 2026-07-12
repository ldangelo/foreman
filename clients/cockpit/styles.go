package main

import (
	"image/color"

	"charm.land/lipgloss/v2"
)

//go:generate go run theme/gen.go

var (
	cGreen  = lipgloss.Color(themeTokenSuccess)
	cYellow = lipgloss.Color(themeTokenWarning)
	cRed    = lipgloss.Color(themeTokenDanger)
	cCyan   = lipgloss.Color(themeTokenAccent)
	cPurple = lipgloss.Color(themeTokenAccent2)
	cText   = lipgloss.Color(themeTokenTextPrimary)
	cDim    = lipgloss.Color(themeTokenTextFaint)
	cWhite  = lipgloss.Color(themeTokenTextPrimary)

	cSelBg       = lipgloss.Color(themeTokenBgSelected)
	cActBg       = lipgloss.Color(themeTokenBgEmphasis)
	cFailBg      = lipgloss.Color(themeTokenBgFailure)
	cActionBg    = lipgloss.Color(themeTokenBgAction)
	cPanel       = lipgloss.Color(themeTokenBorderPrimary)
	cBorderFocus = lipgloss.Color(themeTokenBorderFocus)
	cBorderBlur  = lipgloss.Color(themeTokenBorderBlur)
	cBar         = lipgloss.Color(themeTokenBgBar)
	cHeadBg      = lipgloss.Color(themeTokenBgHeader)
)

var (
	statusBarStyle = lipgloss.NewStyle().Background(cHeadBg).Foreground(cText)
	keyBarStyle    = lipgloss.NewStyle().Background(cBar).Foreground(cDim)
	leftPaneStyle  = lipgloss.NewStyle().BorderStyle(lipgloss.NormalBorder()).BorderRight(true).BorderForeground(cPanel)
	groupStyle     = lipgloss.NewStyle().Bold(true)
	dimStyle       = lipgloss.NewStyle().Foreground(cDim)
	cyanStyle      = lipgloss.NewStyle().Foreground(cCyan)
	purpleStyle    = lipgloss.NewStyle().Foreground(cPurple)
	yellowStyle    = lipgloss.NewStyle().Foreground(cYellow)
	greenStyle     = lipgloss.NewStyle().Foreground(cGreen)
	redStyle       = lipgloss.NewStyle().Foreground(cRed)
	textStyle      = lipgloss.NewStyle().Foreground(cText)
	whiteStyle     = lipgloss.NewStyle().Foreground(cWhite).Bold(true)
)

type paneVisual struct {
	Border     color.Color
	Text       color.Color
	Dim        color.Color
	Green      color.Color
	Yellow     color.Color
	Red        color.Color
	Cyan       color.Color
	Purple     color.Color
	White      color.Color
	SelectedBg color.Color
	ActiveBg   color.Color
	FailBg     color.Color
	ActionBg   color.Color
}

func paneVisualFor(focused bool, cfg FocusConfig) paneVisual {
	style := normalizeFocusStyle(cfg.Style)
	border := cPanel
	if style == focusStyleBoth || style == focusStyleBorder {
		if focused {
			border = cBorderFocus
		} else {
			border = cBorderBlur
		}
	}
	p := paneVisual{
		Border:     border,
		Text:       cText,
		Dim:        cDim,
		Green:      cGreen,
		Yellow:     cYellow,
		Red:        cRed,
		Cyan:       cCyan,
		Purple:     cPurple,
		White:      cWhite,
		SelectedBg: cSelBg,
		ActiveBg:   cActBg,
		FailBg:     cFailBg,
		ActionBg:   cActionBg,
	}
	if !focused && cfg.DimInactive && (style == focusStyleBoth || style == focusStyleDim) {
		p.Text = cDim
		p.Green = cDim
		p.Yellow = cDim
		p.Red = cDim
		p.Cyan = cDim
		p.Purple = cDim
		p.White = cDim
		p.SelectedBg = cPanel
		p.ActiveBg = cPanel
		p.FailBg = cPanel
		p.ActionBg = cPanel
	}
	return p
}

func (p paneVisual) style(c color.Color) lipgloss.Style {
	return lipgloss.NewStyle().Foreground(c)
}

func visualColor(c color.Color, p paneVisual) color.Color {
	switch c {
	case cGreen:
		return p.Green
	case cYellow:
		return p.Yellow
	case cRed:
		return p.Red
	case cCyan:
		return p.Cyan
	case cPurple:
		return p.Purple
	case cWhite:
		return p.White
	case cText:
		return p.Text
	default:
		return c
	}
}

func visualForStatus(status string, p paneVisual) color.Color {
	return visualColor(statusColor(status), p)
}

// glyph returns the status glyph and its color for a phase/run state.
func glyph(state string) (string, color.Color) {
	switch state {
	case "done":
		return "✓", cGreen
	case "active":
		return "●", cCyan
	case "fail":
		return "✗", cRed
	case "retry":
		return "↻", cYellow
	default:
		return "○", cDim
	}
}

// statusColor maps a run status to a color.
func statusColor(status string) color.Color {
	switch status {
	case "running", "in_progress", "pending":
		return cGreen
	case "cooldown":
		return cYellow
	case "failed", "stuck", "conflict", "test-failed":
		return cRed
	case "merged", "completed", "pr-created":
		return cGreen
	default:
		return cYellow
	}
}
