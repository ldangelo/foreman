package main

import (
	"embed"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

//go:embed templates
var templateFS embed.FS

var knownTemplateNames = []string{"basic", "iterate", "parallel", "review", "triage"}

// runInit is the operator-facing "refresh bundled assets" / "scaffold a
// Jobsite script" entry point.
//
// `foreman init --force` (no `--template`) posts to
// `POST /api/admin/workflows/install` and omits every install option so the
// server resolves both the source
// (`Application.app_dir(:foreman_server, "priv/defaults/workflows")`) and
// the target (`System.user_home!()/.foreman/workflows` via
// `Installer.target_dir/1`) from its own configuration. The CLI does not
// resolve any path so that:
//   - remote CLI invocations don't install into the operator's own $HOME,
//   - the server's `Workflow.Catalog` polls that same root and reloads
//     installed manifests on the next poll cycle (default 2s).
//
// `foreman init --template <name>` instead (optionally in addition) writes a
// repo-local `<dir>/.foreman/` scaffold — README, Dockerfile, .gitignore,
// and the named template's runnable `.exs` script plus its prompt file(s) —
// entirely client-side and with no HTTP request. Templates are embedded in
// the binary via `//go:embed templates`, so a remote CLI invocation still
// resolves nothing from the server's filesystem. An existing destination
// file is never overwritten, even with `--force`: `--force` only ever means
// "also run the asset-refresh POST", never "clobber my edited script".
func runInit(c *client.Client, args []string) error {
	fs := newFlagSet("init")
	force := fs.Bool("force", false, "Confirm refresh of installed runtime prompts and workflows")
	template := fs.String("template", "", "Scaffold a repo-local .foreman/ directory from a bundled template (basic, iterate, parallel, review, triage)")
	dir := fs.String("dir", ".", "Directory to scaffold the .foreman/ directory into")
	if err := fs.parse(args); err != nil {
		return err
	}

	if *template == "" {
		if !*force {
			return usageError(
				fs,
				"foreman init: --force is required to refresh the installed runtime copy",
			)
		}

		out, err := doInstall(c)
		if err != nil {
			return err
		}

		return printJSON(out)
	}

	if !knownTemplate(*template) {
		return usageError(
			fs,
			"foreman init: unknown template %q (known: basic, iterate, parallel, review, triage)",
			*template,
		)
	}

	written, skipped, err := scaffoldTemplate(*template, *dir)
	if err != nil {
		return err
	}

	result := map[string]any{
		"template": *template,
		"written":  written,
		"skipped":  skipped,
	}

	if !*force {
		result["install"] = nil
		return printJSON(result)
	}

	install, err := doInstall(c)
	if err != nil {
		return err
	}

	result["install"] = install
	return printJSON(result)
}

// doInstall posts the asset-refresh request. Empty body: server resolves
// source from the running app's bundled priv/defaults/workflows and target
// from the configured catalog root.
func doInstall(c *client.Client) (map[string]any, error) {
	opts := map[string]any{}

	var out map[string]any
	if err := c.PostJSON("/api/admin/workflows/install", opts, &out); err != nil {
		return nil, err
	}

	return out, nil
}

func knownTemplate(name string) bool {
	for _, t := range knownTemplateNames {
		if t == name {
			return true
		}
	}

	return false
}

type templateFile struct {
	src  string // path within templateFS
	dest string // path relative to the scaffold root (<dir>/.foreman)
}

// templateFiles lists every file a named template writes: the shared files
// (README, Dockerfile, .gitignore, and the standalone `foreman_client.exs` the
// HTTP-driven scripts load — the .gitignore's embedded source is named
// "gitignore" without a leading dot so `//go:embed templates` doesn't need
// to special-case dotfile globbing) plus everything under the template's
// own embedded directory (its `.exs` script and any `prompts/*.md` it
// references).
func templateFiles(name string) ([]templateFile, error) {
	files := []templateFile{
		{src: "templates/shared/README.md", dest: "README.md"},
		{src: "templates/shared/Dockerfile", dest: "Dockerfile"},
		{src: "templates/shared/gitignore", dest: ".gitignore"},
		{src: "templates/shared/foreman_client.exs", dest: "foreman_client.exs"},
	}

	root := "templates/" + name
	err := fs.WalkDir(templateFS, root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}

		rel := strings.TrimPrefix(path, root+"/")
		files = append(files, templateFile{src: path, dest: rel})
		return nil
	})
	if err != nil {
		return nil, err
	}

	return files, nil
}

// scaffoldTemplate writes a named template's files into <dir>/.foreman/,
// never overwriting a file that already exists there — a re-run (with or
// without --force) just reports every file as skipped and exits clean.
func scaffoldTemplate(name, dir string) (written, skipped []string, err error) {
	files, err := templateFiles(name)
	if err != nil {
		return nil, nil, err
	}

	sort.Slice(files, func(i, j int) bool { return files[i].dest < files[j].dest })

	root := filepath.Join(dir, ".foreman")
	written = []string{}
	skipped = []string{}

	for _, f := range files {
		destPath := filepath.Join(root, f.dest)

		if _, statErr := os.Stat(destPath); statErr == nil {
			skipped = append(skipped, destPath)
			continue
		} else if !os.IsNotExist(statErr) {
			return nil, nil, statErr
		}

		data, readErr := templateFS.ReadFile(f.src)
		if readErr != nil {
			return nil, nil, readErr
		}

		if mkErr := os.MkdirAll(filepath.Dir(destPath), 0o755); mkErr != nil {
			return nil, nil, mkErr
		}

		if writeErr := os.WriteFile(destPath, data, 0o644); writeErr != nil {
			return nil, nil, writeErr
		}

		written = append(written, destPath)
	}

	return written, skipped, nil
}
