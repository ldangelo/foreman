# Use the task id not the run id for the branch names

The problem with run id is they are long, the user doesn't know them and they don't have an easy way to get them.
Looking at the PR's/Branches the user has NO IDEA what work is in what branch.

# Each Phase gets a commit: tag that is either true or false

When true the phase commits it's code upon completion.

# Each Phase gets a stack_pr: tag that is either true or false

If true the phase will stack a PR onto the open PR.  If this is the first phase it should automatically create a PR.

# Model names should be at the phase level, allowing different models for different phases of the execution

Models should be specified as they are in litellm provider/model.  Provider and model configuration should be in the forman.yaml configuration file.  For example prd.yaml might use anthropic/opus to create a prd and trd but litellm/smart_router to implement the trd.

# Integrate Telegram and Slack messaging

We need to integrate messaging into foreman, currently we are accepting the defaults for all refinements, if we had messaging /refine-prd could use it's --collab --long-lived to return the url that is being exposed on cloudflare, the url could then be sent to the user via messaging so they can refine the prd/trd before continuation.  Returning interactivity into the process.

# Use messaging for stall detection, failure reporting, etc

With messaging integrated we can use it to notify the user when a run appears stalled, fails, errors, etc...
