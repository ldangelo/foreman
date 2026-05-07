# Skill Integration Guide for Foreman

This document describes how the skills in `~/Development/Fortium/foreman/skills/` integrate with Pi.

## Overview

The Foreman project uses a **mixed approach** to skill integration:

1. **Pi Package** for production usage - Installable via `pi install npm:@oftheangels/foreman-skills`
2. **Local Skill Paths** for development/testing - Direct file system access

## Current Skills

| Skill | Location | Purpose | Pi Integration |
|-------|----------|---------|----------------|
| `br` | `skills/br/` | beads_rust task tracker | Available via skill path |
| `bv` | `skills/bv/` | BV task tracker | Available via skill path |
| `jj` | `skills/jj/` | Jujutsu VCS | Available via skill path |
| `foreman` | `skills/foreman/` | Foreman orchestrator | Available via skill path |

## Pi Package Structure

The skills are organized in a directory structure compatible with Pi's skill discovery:

```
skills/
├── br/
│   └── SKILL.md
├── bv/
│   └── SKILL.md
├── jj/
│   └── SKILL.md
└── foreman/
    └── SKILL.md
```

## Integration Methods

### Method 1: Pi Package (Production)

Add a `pi` manifest to `package.json`:

```json
{
  "name": "@oftheangels/foreman-skills",
  "keywords": ["pi-package"],
  "pi": {
    "skills": ["./skills"]
  }
}
```

Install via:
```bash
pi install npm:@oftheangels/foreman-skills
```

### Method 2: Local Skill Paths (Development)

Reference skills directly via command-line flags:

```bash
pi --skill ~/Development/Fortium/foreman/skills/br
pi --skill ~/Development/Fortium/foreman/skills/foreman
pi --skill ~/Development/Fortium/foreman/skills/bv
pi --skill ~/Development/Fortium/foreman/skills/jj
```

Or combine with existing skills:

```bash
pi --skill ~/Development/Fortium/foreman/skills/foreman --skill ~/Development/Fortium/foreman/skills/br
```

## Skill Naming Conventions

Each skill has a name defined in its `SKILL.md` frontmatter:

```markdown
---
name: br
description: "beads_rust (br) issue tracker CLI..."
---
```

Invoke via `/skill:br`, `/skill:foreman`, `/skill:bv`, `/skill:jj`

## Recommended Workflow

### For Development

1. Use local skill paths for active development
2. Test with `pi --skill <path>`
3. Update `SKILL.md` as needed

### For Production

1. Package as an npm package
2. Publish to npm registry
3. Users install via `pi install npm:@oftheangels/foreman-skills`

## Skill Usage Examples

### Using br (beads_rust) Skill

```bash
pi "Help me create a new issue with br"
# Or explicitly invoke
pi /skill:br
br create "New feature" -t feature -p 2
```

### Using foreman Skill

```bash
pi /skill:foreman
foreman task create --title "Add auth" --type feature --priority high
foreman run --bead bd-001
```

## Best Practices

1. **Skill Scope**: Each skill should focus on a single tool/command
2. **Documentation**: Include quick reference for essential commands
3. **When to Use**: Clearly document when the skill should be invoked
4. **Prerequisites**: List any required tools or setup steps
5. **Output Format**: Specify preferred output formats (text, JSON, etc.)

## Future Work

- [ ] Package all skills as `@oftheangels/foreman-skills` npm package
- [ ] Add skill activation hints in agent prompts
- [ ] Create a meta-skill that aggregates all Foreman skills
- [ ] Add skill auto-detection based on project context
