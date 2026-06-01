#!/usr/bin/env python3
"""Fix markdown lint issues in PRD and TRD docs."""

import re

def fix_fenced_blocks(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    lines = content.split('\n')
    fixed = []
    for i, line in enumerate(lines):
        # Fix empty code block markers with text-based content
        if line == '```' and i > 0 and i < len(lines) - 1:
            next_line = lines[i + 1] if i + 1 < len(lines) else ''
            prev_line = lines[i - 1] if i > 0 else ''
            
            # Determine appropriate language
            if next_line.startswith('src/') or next_line.startswith('1.') or next_line.startswith('4.'):
                line = '```text'
            elif next_line.startswith('//') or next_line.startswith('interface ') or next_line.startswith('async function'):
                line = '```typescript'
            elif next_line.startswith('POST') or next_line.startswith('GET'):
                line = '```http'
            elif next_line.startswith('foreman'):
                line = '```bash'
            elif next_line.startswith('#'):
                line = '```bash'
            elif prev_line.strip().endswith('Schema:'):
                line = '```typescript'
            elif prev_line.strip().endswith('Workflow:'):
                line = '```text'
        
        # Fix yaml blocks
        if 'apiUrl' in lines[i+1] if i+1 < len(lines) else '':
            if line == '```':
                line = '```yaml'
        
        fixed.append(line)
    
    return '\n'.join(fixed)

# Fix PRD
content = fix_fenced_blocks('docs/PRD/PRD-2026-013-jira-issue-monitor.md')
with open('docs/PRD/PRD-2026-013-jira-issue-monitor.md', 'w') as f:
    f.write(content)

# Fix TRD - simpler, just add text to diagram blocks
with open('docs/TRD/TRD-2026-013-jira-issue-monitor.md', 'r') as f:
    trd_content = f.read()

# Add text identifier to ASCII diagrams and data flow blocks
trd_content = re.sub(
    r'^(```\n┌─)',
    r'```text\n┌─',
    trd_content,
    flags=re.MULTILINE
)
trd_content = re.sub(
    r'^(```\nEvery pollInterval)',
    r'```text\nEvery pollInterval',
    trd_content,
    flags=re.MULTILINE
)
trd_content = re.sub(
    r'^(```\nJira sends)',
    r'```text\nJira sends',
    trd_content,
    flags=re.MULTILINE
)
trd_content = re.sub(
    r'^(```\nJiraTriggerHandler)',
    r'```text\nJiraTriggerHandler',
    trd_content,
    flags=re.MULTILINE
)
trd_content = re.sub(
    r'^(```\nsrc/daemon)',
    r'```text\nsrc/daemon',
    trd_content,
    flags=re.MULTILINE
)

# Add bash to CLI examples
trd_content = re.sub(
    r'^(```\nforeman)',
    r'```bash\nforeman',
    trd_content,
    flags=re.MULTILINE
)

# Add http to HTTP examples
trd_content = re.sub(
    r'^(```\nPOST /)',
    r'```http\nPOST /',
    trd_content,
    flags=re.MULTILINE
)

with open('docs/TRD/TRD-2026-013-jira-issue-monitor.md', 'w') as f:
    f.write(trd_content)

print('Done fixing code blocks')