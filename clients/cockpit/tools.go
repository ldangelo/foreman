package main

import (
	"fmt"
	"os/exec"
	"strings"
	"sync"
)

type ToolResolver interface {
	Available(name string) bool
	ExtensionAvailable(name string) bool
}

type PathToolResolver struct {
	mu         sync.Mutex
	cache      map[string]bool
	extensions map[string]bool
	extLoaded  bool
}

func NewPathToolResolver() *PathToolResolver {
	return &PathToolResolver{cache: map[string]bool{}, extensions: map[string]bool{}}
}

func (r *PathToolResolver) Available(name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if ok, seen := r.cache[name]; seen {
		return ok
	}
	_, err := exec.LookPath(name)
	ok := err == nil
	r.cache[name] = ok
	return ok
}

func (r *PathToolResolver) ExtensionAvailable(name string) bool {
	r.mu.Lock()
	if r.extLoaded {
		ok := r.extensions[name]
		r.mu.Unlock()
		return ok
	}
	r.mu.Unlock()

	out, err := exec.Command("gh", "extension", "list").Output()

	r.mu.Lock()
	defer r.mu.Unlock()
	r.extLoaded = true
	if err != nil {
		r.extensions = map[string]bool{}
		return false
	}
	r.extensions = parseGhExtensions(string(out))
	return r.extensions[name]
}

func parseGhExtensions(out string) map[string]bool {
	available := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		name := fields[0]
		if name == "gh" && len(fields) > 1 {
			name = "gh-" + fields[1]
		}
		base := name
		if i := strings.LastIndex(base, "/"); i >= 0 {
			base = base[i+1:]
		}
		base = strings.TrimPrefix(base, "gh-")
		available[name] = true
		available[base] = true
	}
	return available
}

var defaultTools ToolResolver = NewPathToolResolver()

func toolAvailable(name string) bool { return defaultTools.Available(name) }

type toolDisabledError struct{ name string }

func (e toolDisabledError) Error() string { return e.name + " disabled" }

func errToolDisabled(name string) error { return toolDisabledError{name: name} }

func errToolMissing(name, install string) error {
	if install == "" {
		return fmt.Errorf("%s not found", name)
	}
	return fmt.Errorf("%s not found — install %s", name, install)
}

func integrationEnabled(mode, tool string, tools ToolResolver) bool {
	switch normalizeEnable(mode) {
	case "off":
		return false
	case "on":
		return true
	default:
		return tools.Available(tool)
	}
}
