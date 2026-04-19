/**
 * Task metadata used for placeholder interpolation in workflow templates.
 */
export interface TaskMeta {
  id: string;
  title: string;
  description: string;
  type: string;
  priority: number;
  /**
   * Stable directory for phase artifacts (PRD, TRD, reports).
   * Computed as join(worktreePath, 'docs', 'reports').
   * Skills write artifacts here so they are versioned with the worktree.
   */
  projectReportsDir?: string;
}

const SUPPORTED_KEYS = new Set<keyof TaskMeta>(['id', 'title', 'description', 'type', 'priority', 'projectReportsDir']);

/**
 * Interpolate `{task.*}` placeholders in a template string with values from task metadata.
 *
 * Supported placeholders:
 * - `{task.id}`         → task.id
 * - `{task.title}`      → task.title
 * - `{task.description}`→ task.description
 * - `{task.type}`       → task.type
 * - `{task.priority}`  → task.priority (converted to string)
 *
 * Behavior:
 * - Unknown placeholders (e.g. `{task.unknown}`) are left as-is and a warning is logged.
 * - Escaped braces `\{task.title\}` emit literal `{task.title}` (no substitution).
 * - Empty / null task fields substitute as empty string.
 * - Backslash before a non-placeholder does not escape — only `\{` is treated as escape.
 *
 * @param template - String containing `{task.*}` placeholders
 * @param task    - Task metadata values to substitute
 * @returns Template with all recognized placeholders replaced
 */
export function interpolateTaskPlaceholders(template: string, task: TaskMeta): string {
  if (!template) return template;

  const result: string[] = [];
  let i = 0;

  while (i < template.length) {
    // Check for escaped placeholder \{task.xxx} — emits literal {task.xxx}
    // Also handle \} escape: emits literal }
    if (template[i] === '\\' && i + 1 < template.length) {
      const next = template[i + 1];
      if (next === '{') {
        // Find closing }
        const braceEnd = template.indexOf('}', i + 2);
        if (braceEnd !== -1) {
          // Escape \{...\}: skip \ at i and \ before }, emit { + content + }
          // e.g. \{task.title\} (0-13): skip \ at 0, take { (1), task.title (2-11), } (13)
          const inner = template.slice(i + 2, braceEnd - 1); // between { and }
          result.push('{' + inner + '}');
          i = braceEnd + 1; // jump past the closing }
          continue;
        }
      } else if (next === '}') {
        // \} escape → emit literal }
        result.push('}');
        i += 2;
        continue;
      }
      // Standalone backslash before non-{ non-} — emit backslash, consume it
      result.push('\\');
      i++;
      continue;
    }

    if (template[i] === '{') {
      const braceEnd = template.indexOf('}', i + 1);
      if (braceEnd === -1) {
        // No closing brace — emit as-is
        result.push(template[i]);
        i++;
        continue;
      }

      const inner = template.slice(i + 1, braceEnd);
      const match = inner.match(/^task\.([a-zA-Z_][a-zA-Z0-9_]*)$/);

      if (match) {
        const key = match[1] as keyof TaskMeta;
        if (SUPPORTED_KEYS.has(key)) {
          const value = task[key];
          result.push(String(value ?? ''));
        } else {
          // Unknown placeholder — leave as-is and warn
          console.warn(
            `[interpolate] Unknown placeholder \`{task.${key}}\` — leaving as-is.`,
          );
          result.push(template.slice(i, braceEnd + 1));
        }
        i = braceEnd + 1;
        continue;
      }

      // Not a placeholder pattern — emit as-is
      result.push(template[i]);
      i++;
      continue;
    }

    result.push(template[i]);
    i++;
  }

  return result.join('');
}
