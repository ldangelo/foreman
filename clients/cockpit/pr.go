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
		BaseBranch: run.BaseBranch,
		BranchName: firstNonEmpty(run.BranchName, run.Branch),
	}
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
