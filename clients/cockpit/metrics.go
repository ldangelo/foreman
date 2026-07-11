package main

import (
	"sort"
	"strings"

	"charm.land/lipgloss/v2"
)

func renderMetricsLines(metrics Metrics, w int, visual paneVisual) []ViewerLine {
	dimStyle := lipgloss.NewStyle().Foreground(visual.Dim)
	cyanStyle := lipgloss.NewStyle().Foreground(visual.Cyan)
	whiteStyle := lipgloss.NewStyle().Foreground(visual.White).Bold(true)
	var lines []ViewerLine
	lines = append(lines, ViewerLine{Key: "metrics:title", Text: cyanStyle.Render("fleet metrics") + dimStyle.Render("  /api/v1/metrics")})
	if len(metrics.Counters) == 0 && len(metrics.Gauges) == 0 && len(metrics.PhaseDuration) == 0 {
		return append(lines, ViewerLine{Key: "metrics:empty", Text: dimStyle.Render("No metrics reported yet.")})
	}
	if len(metrics.Counters) > 0 {
		lines = append(lines, ViewerLine{Key: "metrics:counters", Text: whiteStyle.Render("Counters")})
		for _, key := range sortedMetricKeys(metrics.Counters) {
			lines = append(lines, ViewerLine{Key: "metrics:counter:" + key, Text: metricBar(key, metrics.Counters[key], maxMetricValue(metrics.Counters), w, visual)})
		}
	}
	if len(metrics.Gauges) > 0 {
		lines = append(lines, ViewerLine{Key: "metrics:gauges", Text: ""})
		lines = append(lines, ViewerLine{Key: "metrics:gauges:title", Text: whiteStyle.Render("Gauges")})
		for _, key := range sortedMetricKeys(metrics.Gauges) {
			lines = append(lines, ViewerLine{Key: "metrics:gauge:" + key, Text: metricBar(key, metrics.Gauges[key], max(1, maxMetricValue(metrics.Gauges)), w, visual)})
		}
	}
	if len(metrics.PhaseDuration) > 0 {
		lines = append(lines, ViewerLine{Key: "metrics:durations", Text: ""})
		lines = append(lines, ViewerLine{Key: "metrics:durations:title", Text: whiteStyle.Render("Phase duration")})
		for i, duration := range metrics.PhaseDuration {
			label := duration.PhaseID
			if duration.Status != "" {
				label += " · " + duration.Status
			}
			lines = append(lines, ViewerLine{Key: "metrics:duration:" + itoa(i), Text: metricBar(label, duration.DurationMS/1000, max(1, maxPhaseSeconds(metrics.PhaseDuration)), w, visual)})
		}
	}
	if metrics.EmittedAt != "" {
		lines = append(lines, ViewerLine{Key: "metrics:emitted", Text: ""})
		lines = append(lines, ViewerLine{Key: "metrics:emitted:value", Text: dimStyle.Render("emitted " + metrics.EmittedAt)})
	}
	return lines
}

func sortedMetricKeys(values map[string]int) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func maxMetricValue(values map[string]int) int {
	maxValue := 0
	for _, value := range values {
		if value > maxValue {
			maxValue = value
		}
	}
	return max(1, maxValue)
}

func maxPhaseSeconds(values []PhaseDuration) int {
	maxValue := 1
	for _, value := range values {
		seconds := value.DurationMS / 1000
		if seconds > maxValue {
			maxValue = seconds
		}
	}
	return maxValue
}

func metricBar(label string, value, maxValue, w int, visual paneVisual) string {
	if maxValue < 1 {
		maxValue = 1
	}
	label = strings.ReplaceAll(label, "_", " ")
	barW := max(4, w-28)
	fill := value * barW / maxValue
	if value > 0 && fill == 0 {
		fill = 1
	}
	if fill > barW {
		fill = barW
	}
	bar := strings.Repeat("█", fill) + strings.Repeat("░", barW-fill)
	left := lipgloss.NewStyle().Foreground(visual.Dim).Render(clip(label, 18))
	right := lipgloss.NewStyle().Foreground(visual.Cyan).Render(bar) + " " + lipgloss.NewStyle().Foreground(visual.White).Bold(true).Render(itoa(value))
	return clip(padRow(left, right, w), w)
}
