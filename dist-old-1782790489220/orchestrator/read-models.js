/**
 * Read model interfaces for the orchestrator.
 *
 * These interfaces define the read-only contracts that orchestrator modules
 * use to access store data. Internal type changes in the store implementation
 * should not leak across these boundaries.
 *
 * Key principle: orchestrator modules never construct Run/RunProgress objects,
 * they only read through these interfaces.
 */
export {};
//# sourceMappingURL=read-models.js.map