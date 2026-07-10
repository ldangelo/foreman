package main

import (
	"fmt"
	"os/exec"
	"sync"
)

type ToolResolver interface {
	Available(name string) bool
}

type PathToolResolver struct {
	mu    sync.Mutex
	cache map[string]bool
}

func NewPathToolResolver() *PathToolResolver {
	return &PathToolResolver{cache: map[string]bool{}}
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
