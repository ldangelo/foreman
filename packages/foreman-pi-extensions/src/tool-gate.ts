import type { ForemanExtension, ToolCallEvent, ToolCallResult, ExtensionContext } from './types.js';

// Default bash commands that are always blocked regardless of phase
export const DEFAULT_BASH_BLOCKLIST = [
  'rm -rf /',
  'rm -rf ~',
  'git push --force',
  'git push -f',
  'chmod 777',
  'sudo rm',
  '> /dev/sda',
  'mkfs',
];

// .beads/ is always protected (regardless of allowed tools)
const PROTECTED_PATHS = ['.beads/', '.beads\\'];

export function createToolGateExtension(auditCallback?: (event: object) => void): ForemanExtension {
  return {
    name: 'foreman-tool-gate',
    version: '1.0.0',

    onToolCall(event: ToolCallEvent, ctx: ExtensionContext): ToolCallResult {
      const allowedToolsEnv = process.env.FOREMAN_ALLOWED_TOOLS ?? '';
      const allowedTools = allowedToolsEnv.split(',').map(t => t.trim()).filter(Boolean);
      const phase = process.env.FOREMAN_PHASE ?? 'unknown';

      // If FOREMAN_ALLOWED_TOOLS is empty, allow all (defensive default)
      if (allowedTools.length > 0 && !allowedTools.includes(event.toolName)) {
        const decision = {
          toolName: event.toolName,
          phase,
          blocked: true,
          reason: `Tool ${event.toolName} not allowed in ${phase} phase`,
        };
        auditCallback?.(decision);
        return { block: true, reason: decision.reason };
      }

      // Bash blocklist check
      if (event.toolName === 'Bash' && event.input.command) {
        const command = event.input.command;
        const blocklist = getBashBlocklist();
        for (const pattern of blocklist) {
          if (command.includes(pattern)) {
            const decision = {
              toolName: 'Bash',
              phase,
              blocked: true,
              reason: `Bash command matches blocklist pattern: ${pattern}`,
              command,
            };
            auditCallback?.(decision);
            return { block: true, reason: decision.reason };
          }
        }
      }

      // Protect .beads/ directory for Write/Edit/Bash tools
      const filePath = event.input.file_path ?? event.input.path ?? '';
      if (typeof filePath === 'string' && filePath.length > 0 && PROTECTED_PATHS.some(p => filePath.includes(p))) {
        const decision = {
          toolName: event.toolName,
          phase,
          blocked: true,
          reason: `Writing to .beads/ directory is not allowed`,
          path: filePath,
        };
        auditCallback?.(decision);
        return { block: true, reason: decision.reason };
      }

      return undefined; // allow
    },
  };
}

function getBashBlocklist(): string[] {
  const custom = process.env.FOREMAN_BASH_BLOCKLIST;
  if (custom) {
    return custom.split(',').map(p => p.trim()).filter(Boolean);
  }
  return DEFAULT_BASH_BLOCKLIST;
}

// Default export: pre-constructed instance
export const toolGate = createToolGateExtension();
