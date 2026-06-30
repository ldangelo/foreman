export interface ExecResult {
    stdout: string;
    stderr: string;
    exitCode: number;
}
export declare function runTsxModule(modulePath: string, args: string[], opts: {
    cwd: string;
    timeout?: number;
    env?: NodeJS.ProcessEnv;
}): Promise<ExecResult>;
export declare function execTsxModuleSync(modulePath: string, args: string[], opts?: {
    cwd?: string;
    timeout?: number;
    encoding?: BufferEncoding;
    env?: NodeJS.ProcessEnv;
}): string;
//# sourceMappingURL=tsx-subprocess.d.ts.map