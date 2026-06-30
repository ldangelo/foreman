export interface RegisteredProjectCheckoutSyncOptions {
    projectId?: string;
    projectPath: string;
    defaultBranch?: string | null;
    warn?: (message: string) => void;
}
/** Test-only helper: clear the once-per-state skip-warning cache. */
export declare function resetRegisteredProjectCheckoutWarningCache(): void;
export declare function syncRegisteredProjectCheckout(options: RegisteredProjectCheckoutSyncOptions): void;
//# sourceMappingURL=registered-project-checkout.d.ts.map