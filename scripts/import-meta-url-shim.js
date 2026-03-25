// CJS shim for import.meta.url
// This file is injected by esbuild when bundling to CJS format.
// It provides a module-level `importMetaUrl` variable that replaces
// all `import.meta.url` references in the bundled code.
// In CJS context, __filename is available and points to the current module.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const importMetaUrl = require("url").pathToFileURL(__filename).href;
