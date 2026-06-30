/**
 * Resolve a CLI --project option into an absolute project path.
 *
 * Resolution order:
 * 1. no option → current working directory
 * 2. registered project name via ProjectRegistry.resolve()
 * 3. unregistered absolute path under --project → warn and use directly
 * 4. explicit --project-path absolute path → use directly
 * 5. invalid/unknown input → print a helpful error and exit
 */
export declare function resolveProjectPath(opts: {
    project?: string;
    projectPath?: string;
}): string;
//# sourceMappingURL=project-path.d.ts.map