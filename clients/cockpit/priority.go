package main

import "strings"

func normalizePriorityLabel(priority string) string {
	p := strings.ToUpper(strings.TrimSpace(priority))
	if p == "" {
		return "P2"
	}
	if strings.HasPrefix(p, "P") {
		return p
	}
	return "P" + p
}
