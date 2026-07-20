package main

import (
	"strings"
	"testing"
)

func TestMetricsLabelsNotTruncated(t *testing.T) {
	visual := paneVisualFor(true, defaultConfig().Cockpit.Focus)
	// Use a very long label that would normally be truncated
	longLabel := "this_is_a_very_long_metric_label_that_exceeds_twenty_characters"
	value := 42
	maxValue := 100

	// Render in a narrow pane
	rendered := stripANSI(metricBar(longLabel, value, maxValue, 40, visual))

	// The full label (with spaces instead of underscores) should be present or wrapped
	// Verify no ellipsis in the output
	if strings.Contains(rendered, "…") {
		t.Fatalf("expected no ellipsis in metric bar, got:\n%s", rendered)
	}

	// Verify the key part of the label is preserved (the end "characters")
	if !strings.Contains(rendered, "characters") {
		t.Fatalf("expected metric label to be preserved/wrapped, got:\n%s", rendered)
	}
}
