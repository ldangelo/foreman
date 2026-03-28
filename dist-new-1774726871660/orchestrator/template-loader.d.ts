/**
 * Load a template file from the defaults/prompts/default/ directory.
 * Results are cached to avoid repeated disk I/O.
 *
 * @param filename - Template filename (e.g. "explorer.md" or legacy "explorer-prompt.md").
 *   Must not contain path separators — only bare filenames are accepted.
 *   All callers pass hardcoded filenames; this function is not intended
 *   to be used with user-controlled input.
 * @throws Error if the filename contains a path separator or if the file cannot be read
 */
export declare function loadTemplate(filename: string): string;
/**
 * Replace {{variable}} placeholders in a template string with provided values.
 * Unrecognised placeholders are left as-is.
 *
 * @param template - Template string containing {{variable}} placeholders
 * @param variables - Key/value pairs to substitute
 */
export declare function interpolateTemplate(template: string, variables: Record<string, string>): string;
/**
 * Load a template file and interpolate variables in a single call.
 *
 * @param filename - Template filename (e.g. "explorer.md" or legacy "explorer-prompt.md")
 * @param variables - Key/value pairs to substitute
 */
export declare function loadAndInterpolate(filename: string, variables: Record<string, string>): string;
/**
 * Clear the template cache.
 * Intended for use in tests where template files may be mocked.
 */
export declare function clearTemplateCache(): void;
//# sourceMappingURL=template-loader.d.ts.map