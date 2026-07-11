package main

import (
	"charm.land/bubbles/v2/help"
	"charm.land/bubbles/v2/key"
	"charm.land/lipgloss/v2"
	"strings"
)

type cockpitKeyMap struct {
	viewFocused bool
}

func (k cockpitKeyMap) ShortHelp() []key.Binding {
	if k.viewFocused {
		return []key.Binding{
			binding("↑↓/j/k", "scroll"),
			binding("ctrl+d/u", "page"),
			binding("esc", "tasks"),
			binding("tab", "tab"),
			binding("o", "open"),
			binding("/", "filter"),
			binding("?", "help"),
			binding("q", "quit"),
		}
	}
	return []key.Binding{
		binding("[/] H/L", "section"),
		binding("↑↓/j/k", "task"),
		binding("/", "filter"),
		binding("enter", "details"),
		binding("n", "new"),
		binding("p", "omp"),
		binding("?", "help"),
		binding("q", "quit"),
	}
}

func (k cockpitKeyMap) FullHelp() [][]key.Binding {
	return [][]key.Binding{
		{
			binding("[/] H/L", "task section"),
			binding("↑↓/j/k", "move task/row"),
			binding("/", "filter focused pane"),
			binding("enter", "focus details / open PR"),
			binding("esc", "back/clear/close help"),
			binding("g", "scope current/global"),
		},
		{
			binding("tab/shift+tab", "drill-down tab"),
			binding("1–8", "jump tab"),
			binding("ctrl+d/u", "page details"),
			binding("n/N", "next/prev match"),
			binding("←/→", "pan logs"),
			binding("s", "save visible rows"),
		},
		{
			binding("o", "open selected"),
			binding("d", "selected file diff"),
			binding("n/N", "new task / quick add"),
			binding("y", "copy task id"),
			binding("a", "approve task"),
			binding("e", "edit task"),
			binding("A", "attach run"),
			binding("r/R", "retry/reset run"),
		},
		{
			binding("p/P", "omp triage/plain omp"),
			binding("D", "diffnav"),
			binding("G", "gh dash"),
			binding("C", "gh enhance"),
			binding("?", "toggle help"),
			binding("q", "quit"),
		},
	}
}

func binding(keys, desc string) key.Binding {
	return key.NewBinding(key.WithKeys(keys), key.WithHelp(keys, desc))
}

func renderHelpLine(width int, viewFocused bool) string {
	h := help.New()
	h.SetWidth(width)
	h.Styles = cockpitHelpStyles()
	return h.View(cockpitKeyMap{viewFocused: viewFocused})
}

func renderFullHelp(width int, viewFocused bool) string {
	h := help.New()
	h.SetWidth(width)
	h.Styles = cockpitHelpStyles()
	k := cockpitKeyMap{viewFocused: viewFocused}
	var groups []string
	for _, group := range k.FullHelp() {
		groups = append(groups, h.FullHelpView([][]key.Binding{group}))
	}
	return strings.Join(groups, "\n\n")
}

func cockpitHelpStyles() help.Styles {
	styles := help.DefaultDarkStyles()
	styles.ShortKey = lipgloss.NewStyle().Foreground(cCyan)
	styles.ShortDesc = lipgloss.NewStyle().Foreground(cText)
	styles.ShortSeparator = lipgloss.NewStyle().Foreground(cDim)
	styles.FullKey = lipgloss.NewStyle().Foreground(cCyan)
	styles.FullDesc = lipgloss.NewStyle().Foreground(cText)
	styles.FullSeparator = lipgloss.NewStyle().Foreground(cDim)
	styles.Ellipsis = lipgloss.NewStyle().Foreground(cDim)
	return styles
}
