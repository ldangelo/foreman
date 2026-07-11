package main

import (
	"errors"
	"os/exec"
	"regexp"
	"runtime"
	"strings"
)

type PRStatus struct {
	RunID          string
	Number         string
	URL            string
	State          string
	Mergeable      string
	ReviewDecision string
	Checks         CheckSummary
	HeadSHA        string
	BaseBranch     string
	BranchName     string
	Err            string
}

type CheckSummary struct {
	Passed  int
	Failed  int
	Pending int
}

func prStatusFromRun(run Run) PRStatus {
	return PRStatus{
		RunID:      run.RunID,
		Number:     prNumberFromURL(run.PRURL),
		URL:        run.PRURL,
		State:      run.PRState,
		HeadSHA:    run.PRHeadSHA,
		Checks:     run.Checks,
		BaseBranch: run.BaseBranch,
		BranchName: firstNonEmpty(run.BranchName, run.Branch),
	}
}

func prStatusFromProjection(runID string, raw map[string]any) PRStatus {
	checks := firstObj(raw, "pr_checks", "checks", "check_summary")
	return PRStatus{
		RunID:          runID,
		Number:         prNumberFromURL(str(raw, "pr_url", "pull_request_url")),
		URL:            str(raw, "pr_url", "pull_request_url"),
		State:          str(raw, "pr_state", "state"),
		Mergeable:      str(raw, "pr_mergeable", "mergeable"),
		ReviewDecision: str(raw, "pr_review_decision", "review_decision"),
		Checks: CheckSummary{
			Passed:  firstPositiveInt(intValue(checks["passed"]), intValue(raw["pr_checks_passed"]), intValue(raw["checks_passed"])),
			Failed:  firstPositiveInt(intValue(checks["failed"]), intValue(raw["pr_checks_failed"]), intValue(raw["checks_failed"])),
			Pending: firstPositiveInt(intValue(checks["pending"]), intValue(raw["pr_checks_pending"]), intValue(raw["checks_pending"])),
		},
		HeadSHA:    str(raw, "pr_head_sha", "head_sha"),
		BaseBranch: str(raw, "base_branch"),
		BranchName: str(raw, "branch_name", "branch"),
	}
}

func firstPositiveInt(values ...int) int {
	for _, value := range values {
		if value > 0 {
			return value
		}
	}
	return 0
}

func firstObj(raw map[string]any, keys ...string) map[string]any {
	for _, key := range keys {
		if value, ok := raw[key].(map[string]any); ok {
			return value
		}
	}
	return map[string]any{}
}

var prNumberRe = regexp.MustCompile(`/pull/(\d+)(?:$|[/?#])`)

func prNumberFromURL(u string) string {
	m := prNumberRe.FindStringSubmatch(u)
	if len(m) == 2 {
		return m[1]
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func openPRCommand(pr PRStatus, tools ToolResolver) (*exec.Cmd, error) {
	if strings.TrimSpace(pr.URL) == "" {
		return nil, errors.New("no PR URL for this run")
	}
	if tools.Available("gh") {
		return exec.Command("gh", "pr", "view", "--web", pr.URL), nil
	}
	if runtime.GOOS == "darwin" && tools.Available("open") {
		return exec.Command("open", pr.URL), nil
	}
	if runtime.GOOS == "linux" && tools.Available("xdg-open") {
		return exec.Command("xdg-open", pr.URL), nil
	}
	return nil, errToolMissing("gh", "GitHub CLI or a platform URL opener")
}
