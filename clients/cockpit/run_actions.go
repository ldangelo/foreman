package main

import tea "charm.land/bubbletea/v2"

func retryRun(c Client, run Run) tea.Cmd {
	return func() tea.Msg {
		return runActionDoneMsg{action: "retry requested", runID: run.RunID, taskID: run.TaskID, err: c.RetryRun(run)}
	}
}

func resetRun(c Client, run Run) tea.Cmd {
	return func() tea.Msg {
		return runActionDoneMsg{action: "reset requested", runID: run.RunID, taskID: run.TaskID, err: c.ResetRun(run)}
	}
}

func attachRun(c Client, run Run) tea.Cmd {
	return func() tea.Msg {
		return runActionDoneMsg{action: "attach requested", runID: run.RunID, taskID: run.TaskID, err: c.AttachRun(run)}
	}
}
