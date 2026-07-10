package main

import (
	_ "embed"

	"github.com/charmbracelet/glamour"
)

//go:embed theme/glamour.json
var glamourThemeJSON []byte

func newGlamourRenderer() *glamour.TermRenderer {
	r, err := glamour.NewTermRenderer(
		glamour.WithStylesFromJSONBytes(glamourThemeJSON),
		glamour.WithWordWrap(56),
	)
	if err != nil {
		r, _ = glamour.NewTermRenderer(glamour.WithAutoStyle(), glamour.WithWordWrap(56))
	}
	return r
}
