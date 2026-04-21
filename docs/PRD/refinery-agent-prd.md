# PRD: Refinery Agent

**Document ID:** PRD-REFINERY-AGENT
**Version:** 1.0
**Created:** 2026-04-19
**Status:** Draft
**Type:** Feature

---

## 1. Product Summary

### 1.1 Problem Statement

The current Refinery is a deterministic TypeScript class that handles branch merging and conflict resolution through hardcoded logic. While effective, it lacks:

1. **Contextual awareness**: Cannot reason about merge impact, code quality, or project-specific priorities
2. **Adaptive learning**: Pattern learning exists but is narrowly scoped to conflict resolution tiers
3. **Communication**: No mechanism to inform users about merge decisions, trade-offs, or blockers
4. **Human-in-the-loop**: Limited ability to pause for human input on critical decisions
5. **Flexible strategy selection**: Cannot dynamically choose between merge strategies based on branch characteristics

### 1.2 Solution Overview

Convert the Refinery into an AI-powered agent that:
- Uses LLM reasoning to make intelligent merge decisions
- Maintains awareness of branch history, project context, and team conventions
- Communicates decisions and blockers through the agent mail system
- Provides human-in-the-loop checkpoints for high-risk merges
- Continuously learns from merge outcomes to improve future decisions

### 1.3 Value Proposition

| Before | After |
|--------|-------|
| Hardcoded merge strategies | AI-driven strategy selection based on context |
| Silent failures and conflicts | Proactive communication about merge health |
| Static pattern learning | Dynamic knowledge from merge history and outcomes |
| All-or-nothing merges | Graduated intervention with human checkpoints |
| Monolithic conflict resolution | Tiered escalation with AI reasoning at each level |

---

## 2. User Analysis

### 2.1 Target Users

#### Primary Users

1. **Engineering Teams** using Foreman for automated code review and merge workflows
   - **Pain point**: Unclear merge status, unexpected conflicts, missed deadlines
   - **Need**: Transparent merge pipeline with predictable outcomes

2. **Tech Leads / Engineering Managers**
   - **Pain point**: Lack of visibility into merge queue health and bottlenecks
   - **Need**: High-level dashboards and alerting on merge failures

3. **Developers** receiving merge notifications
   - **Pain point**: Confusing error messages, unclear next steps on conflicts
   - **Need**: Actionable guidance when intervention is required

#### Secondary Users

4. **DevOps / Platform Teams** managing Foreman configuration
   - **Pain point**: Complex YAML configuration for merge behavior
   - **Need**: Intuitive defaults with escape hatches for customization

### 2.2 User Journeys

#### Journey 1: Standard Merge Flow

```
Developer submits task → Agent completes work → Finalize commits → 
Refinery Agent receives → Analyzes branch → Decides strategy → 
Merges or escalates → Notifies via mail
```

#### Journey 2: Conflict Detection

```
Refinery Agent detects conflict → Assesses severity →
Attempts resolution tiers → If unresolved → Creates PR with context →
Notifies developer → Waits for resolution → Completes merge
```

#### Journey 3: Human Escalation

```
Refinery Agent identifies high-risk merge → Pauses pipeline →
Sends escalation mail with options → Developer responds →
Refinery Agent proceeds based on response → Completes or aborts
```

### 2.3 User Stories

| ID | Story | Acceptance Criteria |
|----|-------|-------------------|
| US-001 | As a developer, I want the Refinery Agent to explain why a merge failed | Agent sends mail with specific failure reason and suggested actions |
| US-002 | As a tech lead, I want high-risk merges to require my approval | Agent pauses and sends escalation request before proceeding |
| US-003 | As a developer, I want to see merge queue health at a glance | Agent maintains summary metrics and sends periodic status reports |
| US-004 | As a platform team, I want the agent to learn from team conventions | Agent tracks successful merge patterns and applies them to future merges |
| US-005 | As a developer, I want the agent to auto-retry recoverable failures | Agent implements exponential backoff with max retry limits |

---

## 3. Goals & Non-Goals

### 3.1 Primary Goals

1. **Intelligent Strategy Selection**
   - Analyze branch characteristics (size, age, conflict history, file types)
   - Select optimal merge strategy (squash, fast-forward, recursive, or PR)
   - Adjust strategy based on project configuration and historical success

2. **Transparent Communication**
   - Send structured mail notifications for all merge lifecycle events
   - Provide actionable context in failure messages
   - Maintain merge audit trail for post-mortems

3. **Safe Escalation**
   - Detect high-risk conditions (large diffs, many conflicts, critical paths)
   - Pause for human review when thresholds are exceeded
   - Support manual override and retry instructions

4. **Continuous Learning**
   - Track merge outcomes by branch characteristics, file types, and strategies
   - Build pattern database for future decision-making
   - Surface insights to tech leads via periodic reports

### 3.2 Non-Goals

1. **Full CI/CD replacement**: Refinery Agent complements, not replaces, CI pipelines
2. **Code review automation**: Code review is handled by separate Reviewer phase
3. **Multi-repo support**: Initial scope is single-repo; multi-repo is future work
4. **Direct git operations**: All VCS operations go through VcsBackend abstraction

### 3.3 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Merge success rate | > 95% | (merged / attempted) over 30 days |
| False positive escalations | < 5% | (unnecessary escalations / total) |
| Time to merge (standard) | < 5 min | Pipeline complete → merge done |
| User satisfaction | > 4.0/5 | Post-merge survey (future) |
| Pattern learning accuracy | > 80% | Correct strategy prediction rate |

---

## 4. Functional Requirements

### 4.1 Core Features

#### FR-001: Merge Decision Engine

The Refinery Agent analyzes each completed branch and decides:

1. **Target branch selection**
   - Parse `branch:<name>` label from bead
   - Fall back to project default (e.g., `dev`)
   - Support branch aliases via configuration

2. **Strategy selection**
   - Squash merge: Default for feature branches with clean commits
   - Fast-forward: Only when target has no divergent commits
   - Recursive merge: For long-lived branches with complex history
   - PR creation: When conflicts require human review

3. **Risk assessment**
   - Calculate diff size, file count, conflict probability
   - Check for critical path files (main, config, auth)
   - Evaluate test coverage of changed files

**Decision factors:**

```typescript
interface MergeDecision {
  strategy: 'squash' | 'fast-forward' | 'recursive' | 'pr';
  confidence: number; // 0-1
  riskLevel: 'low' | 'medium' | 'high' | 'critical';
  reasoning: string;
  checkpoints: Checkpoint[];
}
```

#### FR-002: Conflict Resolution Cascade

The Refinery Agent manages conflict resolution with escalating intelligence:

| Tier | Approach | When Invoked | Success Rate Target |
|------|----------|--------------|-------------------|
| 1 | Git merge | All merges | ~70% |
| 2 | Deterministic | Git merge fails | ~85% cumulative |
| 3 | AI Sonnet | Tier 2 fails | ~95% cumulative |
| 4 | AI Opus | Tier 3 fails | ~99% cumulative |
| 5 | Human | All AI fails | 100% |

**Per-file cascade:**
- Each conflicting file runs through tiers independently
- First failure triggers escalation to next tier
- All files must resolve for commit to proceed

#### FR-003: Human-in-the-Loop Checkpoints

The Refinery Agent pauses for human input in these scenarios:

1. **High-risk merge detection**
   - Diff size > 10,000 lines
   - Conflicts in > 5 files
   - Changes to security-critical files
   - Changes to > 50% of core modules

2. **Escalation flow**
   ```
   Agent detects risk → Sends escalation mail →
   Developer responds (approve/reject/modify) →
   Agent proceeds based on response
   ```

3. **Escalation options**
   - `approve`: Proceed with current strategy
   - `reject`: Create PR for manual review
   - `retry`: Retry with different strategy
   - `modify`: Provide custom instructions

#### FR-004: Merge Communication System

The Refinery Agent sends structured notifications:

| Event | Recipients | Content |
|-------|------------|---------|
| `merge-started` | Developer, Tech Lead | Branch info, strategy, ETA |
| `merge-progress` | Developer | Step-by-step status (rebase, resolve, test) |
| `merge-conflict` | Developer | Conflicting files, suggested resolution |
| `merge-escalation` | Tech Lead | Risk summary, decision options |
| `merge-complete` | Developer | Summary, artifacts link, next steps |
| `merge-failed` | Developer, Tech Lead | Failure reason, suggested actions |

**Mail template structure:**

```markdown
## Merge Event: {event_type}

**Branch:** {branch_name}
**Target:** {target_branch}
**Strategy:** {merge_strategy}
**Timestamp:** {ISO_timestamp}

## Details
{event_specific_content}

## Actions
{actionable_next_steps}

---
Foreman Refinery Agent | {agent_id}
```

#### FR-005: Pattern Learning System

The Refinery Agent learns from merge history:

1. **Feature tracking**
   - File types → optimal strategy
   - Branch age → conflict probability
   - Author patterns → quality indicators

2. **Pattern database schema:**

```typescript
interface MergePattern {
  id: string;
  characteristics: {
    fileExtensions: string[];
    diffSize: 'small' | 'medium' | 'large';
    age: number; // days since branch created
    authorTrust: number; // historical success rate
  };
  successfulStrategies: Strategy[];
  successRate: number;
  lastUpdated: string;
}
```

3. **Learning updates**
   - After each merge, update pattern with outcome
   - Decay old patterns (configurable half-life)
   - Prune patterns with insufficient samples

#### FR-006: Merge Queue Intelligence

Enhanced queue management with AI insights:

1. **Smart ordering**
   - Dependencies first (respect bead graph)
   - High-confidence merges before low-confidence
   - Age-based prioritization (avoid stale branches)

2. **Batch optimization**
   - Group non-conflicting branches for parallel processing
   - Identify merge order that minimizes conflicts

3. **Queue health monitoring**
   - Track average time-in-queue
   - Alert on stuck entries (> 1 hour)
   - Surface bottleneck patterns

### 4.2 Feature Specifications

#### FS-001: Branch Analysis Module

**Purpose:** Analyze branches before merge to inform strategy

**Inputs:**
- Branch name and seed ID
- Commit history (count, age, messages)
- Diff statistics (files, lines, types)
- Conflict markers (if any)
- Historical merge data for affected files

**Outputs:**
```typescript
interface BranchAnalysis {
  metrics: {
    commitCount: number;
    age: number; // days
    diffLinesAdded: number;
    diffLinesRemoved: number;
    fileCount: number;
    fileTypes: string[];
    testCoverage: number;
  };
  riskScore: number; // 0-100
  suggestedStrategy: Strategy;
  conflictProbability: number;
  confidence: number;
  warnings: string[];
}
```

#### FS-002: Strategy Selector

**Purpose:** Choose optimal merge strategy based on analysis

**Decision tree:**

```
Start
  ↓
Has divergent commits? ─No→ Fast-forward merge
  ↓ Yes
Has conflicts? ─No→ Squash merge (clean) OR Recursive merge (complex)
  ↓ Yes
Conflict count ≤ 3? ─Yes→ Attempt recursive merge
  ↓ No
Diff size ≤ 5,000? ─Yes→ Attempt Tier 2-4 cascade
  ↓ No
→ Escalate to human (PR creation)
```

**Configuration overrides:**
```yaml
merge_strategy:
  default: squash
  overrides:
    - pattern: "hotfix/*"
      strategy: fast-forward
    - pattern: "release/*"
      strategy: recursive
    - min_conflicts: 10
      strategy: pr
```

#### FS-003: Escalation Manager

**Purpose:** Handle human-in-the-loop scenarios

**Escalation triggers:**

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Diff size | > 10,000 lines | Escalate |
| Conflict count | > 5 files | Escalate |
| Critical files | Auth, main, config | Escalate |
| Failed retries | 3 attempts | Escalate |
| Age | > 7 days stale | Escalate |

**Escalation state machine:**

```
IDLE → ASSESSING → [SAFE → EXECUTING] or [RISKY → WAITING_APPROVAL]
                                              ↓
                              [APPROVED → EXECUTING] or [REJECTED → PR_CREATED]
```

#### FS-004: Outcome Tracker

**Purpose:** Track and report merge outcomes

**Metrics collected:**
- Merge duration (start → complete)
- Strategy used
- Conflicts encountered and resolved
- Escalations triggered
- Retry count
- Test results

**Reports generated:**
- Daily merge summary (per-project)
- Weekly trend analysis
- Monthly retrospective (optional)

---

## 5. Non-Functional Requirements

### 5.1 Performance

| Requirement | Target | Measurement |
|-------------|--------|-------------|
| Merge decision latency | < 2 seconds | Per-branch analysis |
| Conflict resolution (Tier 3) | < 30 seconds | Per-file |
| Queue processing throughput | 10 merges/minute | Sustained rate |
| Memory usage | < 512 MB | Peak during batch |

### 5.2 Reliability

| Requirement | Target |
|-------------|--------|
| Merge success rate | > 95% |
| False positive rate | < 5% |
| Data loss tolerance | Zero (all state persisted) |
| Recovery time | < 30 seconds |

### 5.3 Security

- Agent credentials stored securely (env vars, secrets manager)
- Mail content sanitized (no PII in logs)
- Rate limiting on escalation requests
- Audit log for all merge decisions

### 5.4 Scalability

- Support 100+ concurrent branches
- Handle 10,000+ file repositories
- Process 1,000+ merges per day
- Multi-project support via configuration

---

## 6. Technical Architecture

### 6.1 System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                        Refinery Agent                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
│  │ MergeDecision│  │ Escalation   │  │ Communication        │ │
│  │ Engine       │  │ Manager      │  │ System               │ │
│  └──────────────┘  └──────────────┘  └──────────────────────┘ │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐ │
│  │ Conflict     │  │ Pattern      │  │ Queue                │ │
│  │ Resolver     │  │ Learning      │  │ Intelligence          │ │
│  └──────────────┘  └──────────────┘  └──────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│                     VcsBackend Interface                         │
│                     (Git / Jujutsu)                             │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 Module Responsibilities

| Module | Responsibility | Public API |
|--------|---------------|------------|
| `RefineryAgent` | Orchestrator, main entry point | `processMerge()`, `getStatus()` |
| `MergeDecisionEngine` | Analyze branches, select strategy | `analyze()`, `decide()` |
| `EscalationManager` | Handle human checkpoints | `shouldEscalate()`, `waitForApproval()` |
| `CommunicationSystem` | Send/receive mail | `notify()`, `receiveResponse()` |
| `ConflictResolver` | Existing 4-tier cascade | `resolve()`, `attemptTier()` |
| `PatternLearning` | Track and apply patterns | `learn()`, `predict()` |
| `QueueIntelligence` | Smart queue management | `order()`, `optimize()` |

### 6.3 Data Flow

```
Pipeline Complete
       ↓
Enqueue to MergeQueue
       ↓
RefineryAgent.processMerge()
       ↓
┌─────────────────────────────────────┐
│ 1. BranchAnalysis                   │
│    - Fetch branch metadata          │
│    - Calculate diff stats           │
│    - Check conflict markers         │
└─────────────────────────────────────┘
       ↓
┌─────────────────────────────────────┐
│ 2. MergeDecisionEngine.decide()     │
│    - Evaluate decision factors      │
│    - Select strategy                │
│    - Assess risk level              │
└─────────────────────────────────────┘
       ↓
Risk Assessment
       ↓
┌──────────┐     ┌──────────────┐
│ Low/Med  │────▶│ Execute Merge │
│ Risk     │     │ (no human)    │
└──────────┘     └──────────────┘
       ↓
┌──────────────────┐
│ High/Critical    │
│ Risk             │
└──────────────────┘
       ↓
┌─────────────────────────────────────┐
│ EscalationManager.shouldEscalate()  │
│    - Send escalation mail           │
│    - Wait for response               │
│    - Update decision based on input  │
└─────────────────────────────────────┘
       ↓
Execute Merge Strategy
       ↓
┌─────────────────────────────────────┐
│ ConflictResolver.resolveConflicts()  │
│    - Per-file tier cascade           │
│    - PatternLearning.learn()         │
└─────────────────────────────────────┘
       ↓
Post-Merge
       ↓
┌─────────────────────────────────────┐
│ CommunicationSystem.notify()         │
│    - Send merge-complete mail        │
│    - Update pattern database         │
│    - Archive reports                 │
└─────────────────────────────────────┘
```

### 6.4 State Management

**Merge state machine:**

```typescript
type MergeState = 
  | 'queued'
  | 'analyzing'
  | 'decided'
  | 'awaiting_approval'
  | 'executing'
  | 'resolving_conflicts'
  | 'testing'
  | 'completed'
  | 'failed'
  | 'escalated';

interface MergeContext {
  state: MergeState;
  branchName: string;
  targetBranch: string;
  seedId: string;
  runId: string;
  decision?: MergeDecision;
  conflicts?: ConflictResult[];
  escalationId?: string;
  retryCount: number;
  startedAt: string;
  updatedAt: string;
}
```

---

## 7. Configuration Schema

### 7.1 Agent Configuration

```yaml
# .foreman/config.yaml
refinery_agent:
  # Decision thresholds
  thresholds:
    diff_size_critical: 10000
    diff_size_high: 5000
    conflict_count_critical: 5
    conflict_count_high: 3
    branch_age_stale_days: 7
  
  # Strategy defaults
  default_strategy: squash
  allow_fast_forward: true
  prefer_recursive_for_long_branches: true
  
  # Escalation settings
  escalation:
    enabled: true
    recipients:
      - tech_lead
      - project_owner
    timeout_minutes: 60
    auto_reject_after_timeout: false
  
  # Pattern learning
  learning:
    enabled: true
    min_samples: 10
    decay_days: 90
    export_insights: true
  
  # Communication
  notifications:
    on_start: true
    on_progress: false
    on_conflict: true
    on_escalation: true
    on_complete: true
    on_failure: true
    periodic_summary_hours: 24
```

### 7.2 Strategy Overrides

```yaml
refinery_agent:
  strategy_overrides:
    - name: "Hotfix branches"
      pattern: "hotfix/*"
      strategy: fast_forward
      skip_tests: false
    
    - name: "Release branches"
      pattern: "release/*"
      strategy: recursive
      require_approval: true
    
    - name: "Critical files"
      files: ["src/main/**", "**/auth/**"]
      require_approval: true
      min_reviewers: 2
```

---

## 8. Integration Points

### 8.1 External Systems

| System | Integration | Protocol |
|--------|-------------|----------|
| VcsBackend | Git/Jujutsu operations | Direct |
| Foreman Store | Run state, events | SQLite |
| Agent Mail | Notifications | SQLite mail client |
| Beads | Task status sync | br CLI |
| CI/CD | Test results | Webhook callback |
| Secrets Manager | API keys | Env/Secrets |

### 8.2 Internal Components

| Component | Interface | Purpose |
|-----------|-----------|---------|
| `auto-merge.ts` | Calls `RefineryAgent.processMerge()` | Entry point from pipeline |
| `Refinery` | Wraps `RefineryAgent` for backward compat | Preserves existing API |
| `MergeQueue` | Queue state management | Persistence layer |
| `ConflictResolver` | Per-file resolution | Conflict handling |
| `ConflictPatterns` | Learning database | Pattern storage |

### 8.3 Migration Path

**Phase 1: Wrap existing Refinery**
- Create `RefineryAgent` class
- Keep `Refinery` as thin wrapper
- Enable via feature flag

**Phase 2: Migrate decision logic**
- Move merge decisions to `MergeDecisionEngine`
- Test parity with existing behavior
- Gradual rollout

**Phase 3: Add escalation**
- Implement `EscalationManager`
- Start with notify-only mode
- Enable approval mode after validation

**Phase 4: Pattern learning**
- Implement `PatternLearning`
- Begin collecting outcomes
- Enable recommendations after warm-up

---

## 9. Acceptance Criteria

### 9.1 Core Functionality

| ID | Criterion | Test Scenario |
|----|----------|---------------|
| AC-001 | Agent decides merge strategy correctly | Given branch with conflicts, agent selects PR strategy |
| AC-002 | Agent escalates high-risk merges | Given diff > 10,000 lines, agent sends escalation mail |
| AC-003 | Agent learns from outcomes | Given 10+ merges, agent predicts strategy with > 80% accuracy |
| AC-004 | Agent communicates via mail | Given merge events, mail sent with correct template |
| AC-005 | Agent handles escalations | Given approval response, agent proceeds with merge |

### 9.2 Integration Tests

| ID | Criterion | Test Scenario |
|----|----------|---------------|
| IT-001 | Works with GitBackend | Merge completes successfully |
| IT-002 | Works with JujutsuBackend | Merge completes successfully |
| IT-003 | Syncs with Beads | Bead status updated after merge |
| IT-004 | Integrates with auto-merge | Queue drained correctly |
| IT-005 | Logs events to store | Events queryable after merge |

### 9.3 Performance Tests

| ID | Criterion | Target |
|----|----------|--------|
| PT-001 | Decision latency | < 2 seconds per branch |
| PT-002 | Queue throughput | 10 merges/minute sustained |
| PT-003 | Memory usage | < 512 MB peak |
| PT-004 | Concurrent processing | 5 branches simultaneously |

---

## 10. Error Handling

### 10.1 Error Codes

| Code | Name | Severity | Action |
|------|------|----------|--------|
| RA-001 | Analysis timeout | Medium | Retry with longer timeout |
| RA-002 | Decision inconclusive | Medium | Default to safest strategy |
| RA-003 | Escalation timeout | High | Auto-proceed or abort based on config |
| RA-004 | VCS operation failed | High | Log, alert, abort |
| RA-005 | Mail delivery failed | Low | Log, continue, retry later |
| RA-006 | Pattern learning error | Low | Log, continue, skip learning |
| RA-007 | Merge conflict unresolved | Critical | Create PR, alert developer |

### 10.2 Recovery Procedures

| Scenario | Recovery |
|----------|----------|
| Agent crash during merge | Resume from last checkpoint |
| VCS conflict mid-merge | Abort, mark as failed, alert |
| Escalation timeout | Based on config: auto-proceed or abort |
| Database corruption | Restore from backup, replay from queue |

---

## 11. Future Considerations

### 11.1 Phase 2 Features

1. **Multi-repo support**: Coordinate merges across repositories
2. **Merge previews**: Show diff summary before merge executes
3. **A/B testing**: Test merge strategies in parallel
4. **Custom escalations**: User-defined escalation paths

### 11.2 Phase 3 Features

1. **Predictive merging**: Predict merge success before agent completes
2. **Cross-project learning**: Share patterns across projects
3. **Merge analytics dashboard**: Visualize merge health
4. **Automated rollback**: Auto-revert on post-merge failures

---

## 12. Appendix

### 12.1 Glossary

| Term | Definition |
|------|------------|
| Refinery Agent | AI-powered merge orchestration component |
| Merge Decision | Strategic choice about how to merge a branch |
| Escalation | Request for human input on merge decision |
| Pattern Learning | System that learns from merge outcomes |
| Queue Intelligence | AI-driven queue optimization |

### 12.2 References

- Existing `Refinery` class: `src/orchestrator/refinery.ts`
- ConflictResolver: `src/orchestrator/conflict-resolver.ts`
- MergeQueue: `src/orchestrator/merge-queue.ts`
- VCS Backend: `src/lib/vcs/interface.ts`
- Agent Mail: `src/lib/sqlite-mail-client.ts`

### 12.3 Open Questions

1. Should escalation support async approval via GitHub PR review?
2. How should pattern learning handle team-specific conventions?
3. Should agent decisions be logged for compliance/audit purposes?
4. What's the fallback if LLM API is unavailable?

---

*Document Status: Draft — Pending review and approval*
