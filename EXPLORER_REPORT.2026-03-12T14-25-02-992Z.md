# Explorer Report: Inter-agent messaging system (SQLite mail)

## Summary
Foreman currently uses **file-based communication** for inter-agent coordination: the Lead agent spawns sub-agents (Explorer, Developer, QA, Reviewer) and they exchange information via markdown report files (EXPLORER_REPORT.md, DEVELOPER_REPORT.md, QA_REPORT.md, REVIEW.md). This task requires building a **structured SQLite-backed messaging system** that allows agents to send and receive direct messages, creating a more flexible and trackable communication infrastructure alongside (or replacing) the report file approach.

## Relevant Files

### 1. **src/lib/store.ts** (lines 1-350+)
- **Purpose**: Central SQLite database interface for Foreman state management
- **Current State**:
  - Manages `projects`, `runs`, `costs`, and `events` tables
  - Uses `better-sqlite3` driver (already in dependencies)
  - Has migration system for schema updates
  - No messaging tables or methods currently exist
- **Relevance**: This is where the messaging tables and APIs will be added

### 2. **src/orchestrator/agent-worker.ts** (lines 1-600+)
- **Purpose**: Standalone worker process that executes a single agent session (via SDK query)
- **Current State**:
  - Spawned as detached child process by dispatcher
  - Reads WorkerConfig from JSON file, runs SDK query, updates store with progress
  - Logs to file and tracks tool usage, tokens, costs
  - Lines 158-243: Main SDK query loop that processes messages
- **Relevance**: Agent workers will need to send/receive messages from the mail system

### 3. **src/orchestrator/dispatcher.ts** (lines 1-400+)
- **Purpose**: Dispatches work to agents, manages worktrees, coordinates agent spawning
- **Current State**:
  - Creates workers for ready seeds
  - Resumes stuck/failed agents via SDK session resumption
  - Tracks active agent count and manages concurrency
  - No inter-agent coordination logic (beyond file-based reports)
- **Relevance**: The dispatcher may need to initialize message queue state per run

### 4. **src/orchestrator/roles.ts** (lines 1-283)
- **Purpose**: Agent role definitions, prompts, and report parsing
- **Current State**:
  - Defines 4 roles: explorer, developer, qa, reviewer
  - Each role has ROLE_CONFIGS with model, budget, and report file
  - Includes prompt templates for each role
  - Has utility functions to parse verdicts and issues from reports
- **Relevance**: Role definitions may need messaging capabilities; prompts may need instructions for message-based communication

### 5. **src/orchestrator/lead-prompt.ts** (lines 1-199)
- **Purpose**: Generates the prompt for the Engineering Lead orchestration session
- **Current State**:
  - Lead spawns sub-agents using the Agent tool
  - Sub-agents run sequentially: Explorer → Developer ⇄ QA → Reviewer
  - Current communication: Lead reads report files between phases
  - Lines 184-190: Checks for report files to determine phase completion
- **Relevance**: Lead prompt may need to guide agents on sending/checking messages instead of just writing reports

### 6. **src/orchestrator/types.ts** (lines 1-152)
- **Purpose**: TypeScript type definitions for orchestrator
- **Current State**:
  - Defines RunProgress, EventType, DecompositionPlan structures
  - Event types: dispatch, claim, complete, fail, merge, stuck, restart, recover, conflict, test-fail, pr-created
  - No message-related types
- **Relevance**: Will need new types for Message, Mailbox, MessageQueue

## Architecture & Patterns

### Current Communication Model
1. **File-based (primary)**: Agents write markdown reports; Lead reads them to coordinate
2. **Event logs (secondary)**: store.logEvent() tracks high-level events (dispatch, complete, fail)
3. **Progress tracking**: store.updateRunProgress() tracks agent metrics in JSON
4. **Sequential execution**: Lead orchestrates phases sequentially, reading reports between phases

### SQLite Integration Pattern
- **Database**: `~/.foreman/foreman.db` (configurable)
- **Schema management**: Uses CREATE TABLE IF NOT EXISTS in SCHEMA constant, migrations in MIGRATIONS array
- **Pragmas**: WAL mode (concurrent writes), foreign_keys enabled
- **Prepared statements**: All SQL uses parameterized queries for safety
- **Interfaces**: Separate interfaces for each table entity (Project, Run, Cost, Event)

### Agent Execution Pattern
1. Dispatcher creates WorkerConfig JSON file
2. Spawns detached child process: `tsx agent-worker.ts <config-file>`
3. Worker reads config, runs SDK query(), logs to file
4. Worker updates store with progress/completion
5. Lead reads report files to understand completion state

### Multi-Agent Coordination (Current)
- Lead agent is a single Claude session
- Uses Agent tool to spawn sub-agents in same worktree
- Sub-agents write reports to shared worktree
- Lead reads reports sequentially between phases
- No real-time notifications or direct agent-to-agent communication

## Dependencies

### What Imports Store
- `dispatcher.ts`: Creates/updates runs, logs events
- `agent-worker.ts`: Updates run progress, logs events, queries run state
- `refinery.ts`: Queries completed runs for merging
- `monitor.ts`: Queries run status
- All CLI commands: Check project/run state

### What Imports Agent Roles
- `lead-prompt.ts`: Uses ROLE_CONFIGS to generate team workflow
- `dispatcher.ts`: May reference ROLE_CONFIGS for configuration
- Test files: Verify role prompt generation

### Messaging System Dependencies
- Will depend on `store.ts` for database access
- Will be imported by `agent-worker.ts` to send/check messages
- Will be used by `lead-prompt.ts` to guide agents on messaging
- May integrate with `dispatcher.ts` for mailbox initialization

### External Dependencies Already Present
- `better-sqlite3`: SQLite driver (already in package.json)
- `@anthropic-ai/claude-agent-sdk`: SDK for agent execution
- `chalk`: Terminal colors
- `commander`: CLI parsing

## Existing Tests

### 1. **src/lib/__tests__/store.test.ts**
- Tests ForemanStore methods: createRun, updateRun, getRunsByStatus, etc.
- Tests migrations and schema creation
- **Impact**: New messaging methods in store will need test coverage

### 2. **src/orchestrator/__tests__/agent-worker-team.test.ts**
- Tests lead prompt generation for team mode
- Tests that config.prompt is replaced with lead prompt
- Tests role inclusion/skipping (skipExplore, skipReview)
- **Impact**: May need tests for message-aware prompts

### 3. **src/orchestrator/__tests__/lead-prompt.test.ts**
- Tests lead prompt structure and content
- Verifies team workflow sections are included
- **Impact**: Messaging instructions should be verified in lead prompt tests

### 4. **src/orchestrator/__tests__/agent-worker.test.ts**
- Tests worker config handling, logging setup
- Tests progress tracking and event logging
- **Impact**: May need tests for message sending/receiving

### 5. **src/lib/__tests__/seeds.test.ts**
- Tests seed/beads operations
- Not directly relevant to messaging

## Recommended Approach

### Phase 1: Database Schema & Core Message Store API
1. **Add messaging tables** to SCHEMA in store.ts:
   - `mailboxes`: One per agent in a run (id, run_id, agent_id, created_at)
   - `messages`: Sender, recipient, subject, body, read status, timestamps (id, mailbox_id_sender, mailbox_id_recipient, sender_agent_type, recipient_agent_type, subject, body, read, created_at)
   - Consider indexing on (run_id, recipient_agent_type) and (run_id, sender_agent_type, read) for efficient queries

2. **Add migration** for the new tables in MIGRATIONS array

3. **Create message interfaces** in store.ts:
   - `Mailbox`: id, run_id, agent_type, created_at
   - `Message`: id, sender_mailbox_id, recipient_mailbox_id, sender_agent_type, recipient_agent_type, subject, body, read, created_at, deleted_at (soft delete)

4. **Implement ForemanStore methods**:
   - `sendMessage(runId, senderType, recipientType, subject, body): Message`
   - `getMessages(runId, agentType, unreadOnly?): Message[]`
   - `markMessageRead(messageId): void`
   - `deleteMessage(messageId): void` (soft delete)
   - `getMailbox(runId, agentType): Mailbox | null`

### Phase 2: Agent Worker Integration
1. **Create a messaging module** `src/lib/mail.ts`:
   - Exports `class MailClient` wrapping store methods
   - Methods: sendMessage(), getMessages(), markRead()
   - Handles serialization/deserialization of message bodies

2. **Integrate into agent-worker.ts**:
   - Import MailClient in worker process
   - After each turn, check for new messages: `mailClient.getMessages(runId, currentRole, unreadOnly=true)`
   - If messages exist, include them in the next SDK prompt or tool execution
   - Provide agents a method to send messages via a tool or instruction

3. **Update agent prompts** in roles.ts to include:
   - Instruction to check for messages at the start
   - How to send messages (if implementing as a tool or via store method)
   - Message format expectations

### Phase 3: Lead Coordination Enhancement
1. **Update lead-prompt.ts**:
   - Include message-checking instructions in sub-agent prompts
   - Lead should have a summary of recent messages to understand agent coordination
   - Lead can send "checkpoint" messages to guide agents

2. **Consider task-list coordination**:
   - Agents could check a task list for current phase
   - Messages could provide immediate feedback (not just reports)
   - Potential for asynchronous coordination instead of sequential

### Phase 4: Testing & Documentation
1. **Add store tests** for new messaging methods
2. **Add integration tests** showing message flow through agent execution
3. **Update AGENTS.md** with messaging guidelines for multi-agent teams
4. **Add type documentation** for Message interfaces

## Potential Pitfalls & Edge Cases

### 1. **Message Ordering & Timing**
- If multiple agents send messages simultaneously, order matters for coordination
- Consider using `created_at` timestamps with tie-breaking (ID)
- **Risk**: Race conditions if not careful with concurrent writes
- **Mitigation**: Use SQLite's transactions and WAL mode (already enabled)

### 2. **Message Persistence vs. Cleanup**
- Messages could accumulate over time, bloating the database
- Decide: Archive after read? Keep for audit trail? Soft delete with retention policy?
- **Risk**: Database size growth
- **Mitigation**: Implement message retention policy, periodic cleanup task

### 3. **Agent Identity in Messages**
- How do agents identify themselves? By role (explorer, developer, qa, reviewer)?
- What if same role runs multiple times? Need run_id scoping
- **Risk**: Messages sent to wrong agent instance
- **Mitigation**: Always scope by (run_id, agent_type) tuple; consider run instance IDs

### 4. **Message Format Standardization**
- Free-form text? JSON structure? Markdown?
- Need to be agent-compatible (they parse and generate messages)
- **Risk**: Agents misunderstand message format
- **Mitigation**: Define strict message format in types; include examples in prompts

### 5. **Blocking Behavior**
- Should an agent wait for a response? Timeout? Retry?
- File-based reports are synchronous (write then wait for read)
- Messages are asynchronous (might not be read immediately)
- **Risk**: Agents get stuck waiting for messages that never come
- **Mitigation**: Implement timeout mechanism; define fallback behavior

### 6. **Lead Responsiveness**
- Currently lead reads reports sequentially after spawning each agent
- With messaging, lead needs to respond to agent messages quickly
- **Risk**: Agents stuck waiting for lead feedback
- **Mitigation**: Consider message polling loop in lead session or scheduled polling

### 7. **Backward Compatibility**
- Existing agent prompts expect file-based reports
- New messaging system must coexist with (or gracefully replace) file-based approach
- **Risk**: Partial migration breaks agent coordination
- **Mitigation**: Support both systems during transition; phase out gradually

### 8. **Message Privacy & Scoping**
- Should agents see messages intended for other agents?
- Should lead see all messages or just summary?
- **Risk**: Agents access messages out of scope
- **Mitigation**: Implement fine-grained access control in mail.ts queries

## Next Steps for Developer

1. **Database Schema Design** — Finalize message table structure with consideration for:
   - Query patterns (efficient lookup by run_id + agent_type)
   - Soft deletes vs. hard deletes
   - Retention policies
   - Indexes for performance

2. **Implement Store Methods** — Add ForemanStore messaging methods to store.ts

3. **Create MailClient** — Implement src/lib/mail.ts with high-level message API

4. **Integration** — Wire messaging into agent-worker.ts execution loop

5. **Agent Prompt Updates** — Update roles.ts prompts to include messaging guidance

6. **Tests** — Write comprehensive tests for messaging system at all layers

7. **Documentation** — Update AGENTS.md and add code comments explaining message flow

## Architecture Diagram (Proposed)

```
Agent Worker Process 1 (Explorer)
  └─ MailClient.sendMessage("developer", "Ready to implement")
     └─ ForemanStore.sendMessage()
        └─ SQLite messages table

Lead Agent Session
  └─ Polls mailboxes for all agents
     └─ Reads recent messages
        └─ ForemanStore.getMessages()
           └─ SQLite messages table

Agent Worker Process 2 (Developer)
  └─ MailClient.getMessages("developer")
     └─ Checks for explorer feedback
        └─ ForemanStore.getMessages()
           └─ SQLite messages table
```
