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
		BaseBranch: str(raw, "base_branch", "base_ref", "target_branch"),
		BranchName: str(raw, "branch_name", "branch"),
	}
}

func hasPRStatus(pr PRStatus) bool {
	return pr.URL != "" ||
		pr.State != "" ||
		pr.Mergeable != "" ||
		pr.ReviewDecision != "" ||
		pr.HeadSHA != "" ||
		pr.BaseBranch != "" ||
		pr.BranchName != "" ||
		pr.Checks.Passed > 0 ||
		pr.Checks.Failed > 0 ||
		pr.Checks.Pending > 0
}

func prStatusFromEventRows(runID string, rows []map[string]any) PRStatus {
	out := PRStatus{RunID: runID}
	for _, row := range rows {
		if eventRunID(row) != "" && eventRunID(row) != runID {
			continue
		}
		out = mergePRStatus(out, prStatusFromEventRow(runID, row))
	}
	return out
}

func eventRunID(row map[string]any) string {
	if runID := str(row, "run_id"); runID != "" {
		return runID
	}
	return str(obj(row, "payload"), "run_id")
}

func prStatusFromEventRow(runID string, row map[string]any) PRStatus {
	payload := obj(row, "payload")
	if payload == nil {
		payload = row
	}

	raw := map[string]any{}
	for key, value := range payload {
		raw[key] = value
	}
	for key, value := range row {
		if _, exists := raw[key]; !exists {
			raw[key] = value
		}
	}

	pr := prStatusFromProjection(runID, raw)
	switch str(row, "event_type", "type") {
	case "PrUpdated":
		if pr.State == "" {
			pr.State = firstNonEmpty(str(raw, "pr_state"), "draft")
		}
	case "PrReady":
		if pr.State == "" {
			pr.State = "open"
		}
	case "PrRetargeted":
		if pr.State == "" {
			pr.State = firstNonEmpty(str(raw, "pr_state"), "open")
		}
		if pr.BaseBranch == "" {
			pr.BaseBranch = str(raw, "new_base_branch")
		}
	case "PrReset":
		if pr.State == "" {
			pr.State = "closed"
		}
	case "PrMerged":
		if pr.State == "" {
			pr.State = "merged"
		}
	}
	if pr.URL == "" {
		pr.URL = str(raw, "url")
		pr.Number = prNumberFromURL(pr.URL)
	}
	if pr.HeadSHA == "" {
		pr.HeadSHA = str(raw, "head_ref_oid", "headRefOid")
	}
	if pr.BaseBranch == "" {
		pr.BaseBranch = str(raw, "base_ref", "base_ref_name", "baseRefName")
	}
	if pr.BranchName == "" {
		pr.BranchName = str(raw, "head_ref_name", "headRefName")
	}
	if pr.ReviewDecision == "" {
		pr.ReviewDecision = str(raw, "review", "reviewDecision")
	}
	return pr
}

func mergePRStatus(base, next PRStatus) PRStatus {
	if base.URL == "" {
		base.URL = next.URL
		base.Number = next.Number
	}
	if base.Number == "" {
		base.Number = next.Number
	}
	if base.State == "" {
		base.State = next.State
	}
	if base.Mergeable == "" {
		base.Mergeable = next.Mergeable
	}
	if base.ReviewDecision == "" {
		base.ReviewDecision = next.ReviewDecision
	}
	if base.HeadSHA == "" {
		base.HeadSHA = next.HeadSHA
	}
	if base.BaseBranch == "" {
		base.BaseBranch = next.BaseBranch
	}
	if base.BranchName == "" {
		base.BranchName = next.BranchName
	}
	if base.Checks.Passed == 0 {
		base.Checks.Passed = next.Checks.Passed
	}
	if base.Checks.Failed == 0 {
		base.Checks.Failed = next.Checks.Failed
	}
	if base.Checks.Pending == 0 {
		base.Checks.Pending = next.Checks.Pending
	}
	return base
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
