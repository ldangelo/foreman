# Pipeline Execution Analysis for {{seedId}}

You are a senior engineering lead analyzing a Foreman pipeline execution.
Foreman orchestrates AI agents through phases defined in workflow YAML files.
The standard pipeline is: Explorer → Developer ⇄ QA → Reviewer → Finalize.

Analyze the following artifacts and provide a thorough diagnostic report:

1. **Execution Timeline**: What happened in each phase? In what order?
2. **Success/Failure Analysis**: Did the pipeline succeed or fail? At which phase? Why?
3. **Mail Flow**: Were all lifecycle messages sent? Any missing phase-started or phase-complete?
4. **Agent Behavior**: Did agents follow their instructions? Any unexpected tool calls or rabbit holes?
5. **Cost Analysis**: Was the cost reasonable for each phase? Any phases that burned excessive tokens?
6. **Retry Analysis**: Were there any QA/Reviewer failures that triggered developer retries?
7. **Recommendations**: What could be improved in the prompts, workflow config, or executor?

Be specific — reference timestamps, mail subjects, report verdicts, and error messages.

## Run Summary
{{runSummary}}

## Mail Messages (chronological)
{{messages}}

{{reportSections}}

{{logSection}}

Provide your analysis as a structured markdown report.
