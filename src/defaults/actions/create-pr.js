/**
 * Foreman project action.
 * Edit this file in .foreman/actions to customize behavior without rebuilding Foreman.
 */
export default async function run(ctx) {
  return ctx.internal.runBuiltin();
}
