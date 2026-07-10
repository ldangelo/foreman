package main

import "github.com/charmbracelet/lipgloss"

//go:generate go run theme/gen.go

var (
	cGreen  = lipgloss.Color(themeTokenSuccess)
	cYellow = lipgloss.Color(themeTokenWarning)
	cRed    = lipgloss.Color(themeTokenDanger)
	cCyan   = lipgloss.Color(themeTokenAccent)
	cPurple = lipgloss.Color(themeTokenAccent2)
	cText   = lipgloss.Color(themeTokenTextPrimary)
	cDim    = lipgloss.Color(themeTokenTextFaint)
	cWhite  = lipgloss.Color("#ffffff")

	cSelBg    = lipgloss.Color(themeTokenBgSelected)
	cActBg    = lipgloss.Color(themeTokenBgEmphasis)
	cFailBg   = lipgloss.Color(themeTokenBgFailure)
	cActionBg = lipgloss.Color(themeTokenBgAction)
	cPanel    = lipgloss.Color(themeTokenBorderPrimary)
	cBar      = lipgloss.Color(themeTokenBgBar)
	cHeadBg   = lipgloss.Color(themeTokenBgHeader)
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

// glyph returns the status glyph and its color for a phase/run state.
func glyph(state string) (string, lipgloss.Color) {
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
func statusColor(status string) lipgloss.Color {
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
