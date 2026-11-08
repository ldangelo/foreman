# SunStone Partners Software Factory

## Introlduction

Foreman is designed to be and end-to-end software factory that starts with an idea and finishes with a high quality implementation for the 'idea'.

The design is a client/server architecture where the server executes agents in a sandboxed environments using kubernetes for scale.

The factory includes the following features:

- idea: take a raw idea, research possible solutions, identify primary users and use cases, rank the idea's priority and recommend go/no-go on wether we should persue the idea.
- prd: once an idea has been cultivated create a full PRD using ensemble's create-prd and refine-prd workflow.
- trd: create a TRD by using ensemble's create-trd workflow.
- implement: implement the TRD using ensemble's implement-trd workflow.
- review: review the resulting PR, perform static code analysis, validate all tests pass and classify the risk of merging into HIGH, MEDIUM and LOW.
  Justification for the risk must be added to the PR as a comment with specific review instructions for human review.
- merge: HIGH risk PR's require 1 human review, MEDIUM/LOW risk PR's can be automatically merged.

## Rules

- context: projects should provide there own context and constition to foreman.
- worktrees: work should always be performed in an isolated branch in a separate worktree.
- improvements: After each run foreman should record key learnings in the integrated memory store, audit it's runs and recommend improvements (using kata) for foreman, ensemble, litellm and/or the current project.  It should constantly improve itself.
- communication: Since foreman is designed to be headless it should have the concept of communication channels.  Initial implementations will include telegram and slack with the ability for others to be added.
  communication channels are designed to be bi-directional, they can be used to ask the user(s) a question and get a response.

## Integrations

Where possible foreman should use the 'unix' philosphy and extend existing tools rather than build it's own.  

Below is a list of tools that are useful foundationally, recommend additional tools where appropriate.

- gh: the github cli.
- wt: work tree management.
- kata: AI first task manager that can drive agents.
- herdr: expose sub-agents, etc...
- git: source code control (obviously)
- litellm: for model routing, governence, compliance, logging/tracing and metrics.
- npx skills: to install manage skills
- claude: optional coding harness
- pi: preferred target coding harness
- codex: optional target coding harness

We also need some sort of 'memory' for foreman so that it can learn overtime, recommend a memory solution that will hopefully get installed and deployed alongside litellm.

## Approaches to investigate

1) Search the web for existing solutions and ideas for a software factory and or agent orchestration engine.
2) here are some potential ideas:

<https://conductor-oss.github.io/conductor/devguide/ai/index.html>
<https://temporal.io/>
