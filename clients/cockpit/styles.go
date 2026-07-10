package main

import "github.com/charmbracelet/lipgloss"

// Self-contained dark terminal palette (matches the design mockup).
var (
	cGreen  = lipgloss.Color("#7ee787")
	cYellow = lipgloss.Color("#e5c07b")
	cRed    = lipgloss.Color("#ff7b72")
	cCyan   = lipgloss.Color("#56b6c2")
	cPurple = lipgloss.Color("#b392f0")
	cText   = lipgloss.Color("#c8ccd4")
	cDim    = lipgloss.Color("#6b7280")
	cWhite  = lipgloss.Color("#ffffff")

	cSelBg    = lipgloss.Color("#1f2a44")
	cActBg    = lipgloss.Color("#13303a")
	cFailBg   = lipgloss.Color("#3a1414")
	cActionBg = lipgloss.Color("#0f1a12")
	cPanel    = lipgloss.Color("#2b2f3a")
	cBar      = lipgloss.Color("#0c0e13")
	cHeadBg   = lipgloss.Color("#161922")
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
