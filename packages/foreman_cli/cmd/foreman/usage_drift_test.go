package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// subcommandDispatchers maps a top-level verb to the function whose first
// `switch args[0]` selects its subcommand. A top-level verb that is absent here
// has no subcommand switch (`usage`, `init`, `doctor`).
var subcommandDispatchers = map[string]string{
	"project":   "runProject",
	"run":       "runRun",
	"thread":    "runThread",
	"workflow":  "runWorkflow",
	"approvals": "runApprovals",
	"questions": "runQuestions",
	"commands":  "runCommands",
}

// switchCases returns the string-literal case labels of the first switch in
// the named function, parsed from the package's Go source.
func switchCases(t *testing.T, funcName string, switchOn func(ast.Expr) bool) []string {
	t.Helper()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range files {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Name.Name != funcName {
				continue
			}
			var cases []string
			found := false
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				sw, ok := n.(*ast.SwitchStmt)
				if !ok || found || !switchOn(sw.Tag) {
					return !found
				}
				found = true
				for _, stmt := range sw.Body.List {
					for _, expr := range stmt.(*ast.CaseClause).List {
						if lit, ok := expr.(*ast.BasicLit); ok && lit.Kind == token.STRING {
							v, _ := strconv.Unquote(lit.Value)
							cases = append(cases, v)
						}
					}
				}
				return false
			})
			if !found {
				t.Fatalf("%s: no matching switch found", funcName)
			}
			return cases
		}
	}
	t.Fatalf("function %s not found", funcName)
	return nil
}

func isArgs0(e ast.Expr) bool {
	idx, ok := e.(*ast.IndexExpr)
	if !ok {
		return false
	}
	id, ok := idx.X.(*ast.Ident)
	return ok && id.Name == "args"
}

func isOsArgs1(e ast.Expr) bool {
	idx, ok := e.(*ast.IndexExpr)
	if !ok {
		return false
	}
	sel, ok := idx.X.(*ast.SelectorExpr)
	return ok && sel.Sel.Name == "Args"
}

// dispatchedVerbs returns every "<command>" and "<command> <sub>" the CLI
// dispatches, read from the dispatch switches themselves.
func dispatchedVerbs(t *testing.T) (top []string, subs map[string][]string) {
	t.Helper()
	top = switchCases(t, "main", isOsArgs1)
	sort.Strings(top)
	subs = map[string][]string{}
	for cmd, fn := range subcommandDispatchers {
		got := switchCases(t, fn, isArgs0)
		sort.Strings(got)
		subs[cmd] = got
	}
	return top, subs
}

// usageLines returns the verb lines of the `usage` const's Commands block.
func usageLines() []string {
	var lines []string
	in := false
	for _, line := range strings.Split(usage, "\n") {
		switch {
		case line == "Commands:":
			in = true
		case line == "Env:":
			in = false
		case in && strings.HasPrefix(line, "  "):
			lines = append(lines, strings.TrimSpace(line))
		}
	}
	return lines
}

var wordRe = regexp.MustCompile(`^[a-z][a-z-]*(\|[a-z][a-z-]*)*$`)

// advertisedVerbs parses the usage lines into the set of "<command>" and
// "<command> <sub>" strings they advertise ("a|b|c" expands to each).
func advertisedVerbs() map[string]bool {
	out := map[string]bool{}
	for _, line := range usageLines() {
		fields := strings.Fields(line)
		cmd := fields[0]
		out[cmd] = true
		if len(fields) > 1 && wordRe.MatchString(fields[1]) {
			for _, sub := range strings.Split(fields[1], "|") {
				out[cmd+" "+sub] = true
			}
		}
	}
	return out
}

func TestUsageAdvertisesExactlyTheDispatchedVerbs(t *testing.T) {
	top, subs := dispatchedVerbs(t)
	advertised := advertisedVerbs()

	dispatched := map[string]bool{}
	for _, cmd := range top {
		dispatched[cmd] = true
		for _, sub := range subs[cmd] {
			dispatched[cmd+" "+sub] = true
		}
	}

	for verb := range dispatched {
		if !advertised[verb] {
			t.Errorf("verb %q is dispatched but missing from the usage const", verb)
		}
	}
	for verb := range advertised {
		if !dispatched[verb] {
			t.Errorf("usage advertises %q but the dispatch switches do not route it", verb)
		}
	}
}

func readCLIReference(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "docs", "cli-reference.md"))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestCLIReferenceDocumentsEveryDispatchedVerb(t *testing.T) {
	doc := readCLIReference(t)
	top, subs := dispatchedVerbs(t)

	for _, cmd := range top {
		if len(subs[cmd]) == 0 {
			if !regexp.MustCompile(`foreman\s+` + cmd + `\b`).MatchString(doc) {
				t.Errorf("docs/cli-reference.md does not document `foreman %s`", cmd)
			}
			continue
		}
		for _, sub := range subs[cmd] {
			re := regexp.MustCompile(`foreman\s+` + cmd + `\s+` + regexp.QuoteMeta(sub) + `\b`)
			// approvals/questions are documented as `foreman approvals list ... | approve ...`.
			alt := regexp.MustCompile(`foreman\s+` + cmd + `\s+[^\n]*\b` + regexp.QuoteMeta(sub) + `\b`)
			if !re.MatchString(doc) && !alt.MatchString(doc) {
				t.Errorf("docs/cli-reference.md does not document `foreman %s %s`", cmd, sub)
			}
		}
	}
}

func TestAgentCommandSpecsRouteToDispatchedVerbs(t *testing.T) {
	_, subs := dispatchedVerbs(t)
	advertised := advertisedVerbs()
	for _, spec := range buildAgentCommandInventory(nil) {
		cmd, sub := spec.CLI[1], spec.CLI[2]
		known := false
		for _, s := range subs[cmd] {
			known = known || s == sub
		}
		if !known {
			t.Errorf("agent command %s wraps `foreman %s %s`, which is not dispatched", spec.ID, cmd, sub)
		}
		if !advertised[cmd+" "+sub] {
			t.Errorf("agent command %s wraps `foreman %s %s`, which usage does not advertise", spec.ID, cmd, sub)
		}
	}
}

func TestDriftCheckCanFail(t *testing.T) {
	top, subs := dispatchedVerbs(t)
	if len(top) < 10 || len(subs["run"]) < 17 {
		t.Fatalf("dispatch parser found too little (top=%v run=%v)", top, subs["run"])
	}
	// A verb the CLI removed ("task retry") must not be advertised, and the
	// parser must see it as undispatched.
	if advertisedVerbs()["task retry"] {
		t.Fatal("usage advertises removed verb task retry")
	}
	for _, cmd := range top {
		if cmd == "task" {
			t.Fatal("task unexpectedly dispatched")
		}
	}
	// Negative control for the spec validator.
	bad := []agentCommandSpec{{ID: "foreman-run-bogus", Kind: "run", CLI: []string{"foreman", "run", "nonexistent"}, Tags: []string{"foreman", "run"}}}
	if err := validateAgentCommandSpecs(bad); err == nil {
		t.Fatal("validateAgentCommandSpecs accepted a nonexistent subcommand")
	}
}

// Every `foreman <verb>` stub the reference marks NOT IMPLEMENTED ("is not
// dispatched") must really be undispatched.
var notDispatchedClaim = regexp.MustCompile("`foreman ([a-z][a-z -]*?)` is not (?:dispatched|a `[a-z]+` subcommand)")

func staleNotImplementedClaims(doc string, top []string, subs map[string][]string) []string {
	dispatched := map[string]bool{}
	for _, cmd := range top {
		dispatched[cmd] = true
		for _, sub := range subs[cmd] {
			dispatched[cmd+" "+sub] = true
		}
	}
	var stale []string
	for _, m := range notDispatchedClaim.FindAllStringSubmatch(doc, -1) {
		if dispatched[m[1]] {
			stale = append(stale, m[1])
		}
	}
	return stale
}

func TestCLIReferenceNotImplementedClaimsAreAccurate(t *testing.T) {
	top, subs := dispatchedVerbs(t)
	if stale := staleNotImplementedClaims(readCLIReference(t), top, subs); len(stale) > 0 {
		t.Fatalf("docs/cli-reference.md claims these dispatched verbs are NOT dispatched: %v", stale)
	}
}

func TestNotImplementedCheckCanFail(t *testing.T) {
	top, subs := dispatchedVerbs(t)
	doc := "> **NOT IMPLEMENTED.** `foreman run merge` is not dispatched. There is no operator merge verb."
	if got := staleNotImplementedClaims(doc, top, subs); len(got) != 1 || got[0] != "run merge" {
		t.Fatalf("stale claim not detected: %v", got)
	}
}
