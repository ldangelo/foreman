/**
 * Foreman qlty action.
 *
 * Runs `qlty check` by default and writes QLTY_REPORT.md.
 * Edit this file in .foreman/actions to customize behavior without rebuilding Foreman.
 */
export default async function run(ctx) {
  return ctx.internal.runBuiltin();
}
