
# Introduction

I want to simplify foreman's behavior dramatically, currently foreman dispatches tasks from the task list.  We've added support to execute workflows by queuing runs and handing the command a workflow name and arguments.

# Ensemble based workflows only

We will remove all the existing workflows and prompts.  We will move to a currated set of workflows with specific purposes.

## PRD

This workflow will take a prompt with the feature to be implemented and execute the full ensemble suite:

1) /skill:ensemble-full-create-prd {prompt} --foreman
2) /skill:ensemble-full-refine-prd {path to prd}  --foreman
3) /skill:ensemble-full-create-trd {path to prd} --foreman
4) /skill:ensemble-full-implement-trd {path to trd}} --foreman

This workflow will operate in a worktree.  Ensemble will likely need updating to accept --foreman.  It should pick the recommendations during refinement and not prompt for user input (since there isn't one).  When done it should create a pr (I think this is part of ensemble double check)

## TRD

This workflow will take in a PRD and implement it exactly like above but without needing to create a PRD.

## FIX

This workflow will behave like the others except it will call /skill:ensemble-full-fix-issue {prompt}

Work will be dispatched through foreman using the run queue and these three prompts.  This should give us EVERYTHING we need in the short term.
Obviously this eliminates the need for tasks but we will leave them for now just in case.

# Open Question

Obviously those skills are pi/omp specific syntax.  How can we make this more general so that pi, claude, codex, opencode, etc... back ends work without having to modify the workflows?  Additionally foreman needs to check to ensure the backend being used has ensemble installed and provide an error and installation instructions.  Don't just assume it is there.

Can the run dispatch command/mcp also allow a backend selection?  For example if the default is pi and we want to execute using claude the user should be able to queue work for the claude backend (assuming it is installed and configured)
