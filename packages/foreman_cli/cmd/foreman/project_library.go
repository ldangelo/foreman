package main

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"text/tabwriter"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

const projectLibraryUsage = `Usage:
  foreman project library list [--format=json|table] <project-id>
  foreman project library add [--name=<name>] [--format=json|table] <project-id> <path>...
  foreman project library replace [--name=<name>] [--format=json|table] <project-id> <entry-id> <path>...
  foreman project library remove <project-id> <entry-id>

The library holds files and folders every agent of the project can read (read-only,
at $FOREMAN_LIBRARY_PATH). 'add' takes either one folder or one or more files:
a folder is walked here with the server's rules (skips hidden files, node_modules,
symlinks and files over 30 MB; at most the first 100 files within 200 MB; at most 10
folders per project), files are limited to 100 per add and 480 MB each, and one add may
carry at most 512 MiB in total (one request). The server applies the same rules again and
stays authoritative. Every skipped file is printed.
--format=json prints the server response with the local skipped list merged in.`

// The Library limits, mirrored from the server's `config :foreman_server, :library`
// so the CLI can report what it left out; the server enforces them regardless.
const (
	libraryMaxFilesPerAdd = 100
	libraryMaxFileBytes   = 480 * 1024 * 1024
	libraryFolderMaxFiles = 100
	libraryFolderMaxBytes = 200 * 1024 * 1024
	libraryFolderSkipFile = 30 * 1024 * 1024
	// One add is one request; the server refuses a larger body only after reading all of it
	// (`upload_max_bytes`, reported in the `limits` of `library list`).
	libraryUploadMaxBytes = 512 * 1024 * 1024
)

type libraryUploadPlan struct {
	kind        string
	defaultName string
	files       []client.UploadFile
	skipped     []map[string]string
}

// projectLibrary dispatches `foreman project library <verb>`.
func projectLibrary(c *client.Client, args []string) error {
	if len(args) == 0 {
		return usageTextError("foreman project library: missing subcommand (list|add|replace|remove)", projectLibraryUsage)
	}

	switch args[0] {
	case "list":
		return projectLibraryList(c, args[1:])
	case "add":
		return projectLibraryAdd(c, args[1:])
	case "replace":
		return projectLibraryReplace(c, args[1:])
	case "remove":
		return projectLibraryRemove(c, args[1:])
	default:
		return usageTextError(fmt.Sprintf("foreman project library: unknown subcommand %q", args[0]), projectLibraryUsage)
	}
}

func libraryBase(projectID string) string {
	return client.JoinPath("/api/projects", url.PathEscape(projectID), "library")
}

func checkLibraryFormat(fs *flagSet, verb, format string) error {
	switch format {
	case "", "table", "json":
		return nil
	default:
		return usageError(fs, "foreman project library %s: unsupported format %q", verb, format)
	}
}

func projectLibraryList(c *client.Client, args []string) error {
	fs := newFlagSet("project library list")
	format := fs.String("format", "", "Output format (table|json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return usageError(fs, "foreman project library list: expected one argument: <project-id>")
	}
	if err := checkLibraryFormat(fs, "list", *format); err != nil {
		return err
	}

	var out struct {
		Entries []map[string]any `json:"entries"`
		Index   string           `json:"index"`
		Limits  map[string]any   `json:"limits"`
	}
	if err := c.GetJSON(libraryBase(fs.Arg(0)), &out); err != nil {
		return err
	}

	if *format == "json" {
		return printJSON(out)
	}

	tw := tabwriter.NewWriter(os.Stdout, 0, 8, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tNAME\tKIND\tFILES\tBYTES")
	for _, e := range out.Entries {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%v\t%v\n", getStr(e, "entry_id"), getStr(e, "name"), getStr(e, "kind"), e["file_count"], e["bytes"])
	}
	return tw.Flush()
}

func projectLibraryAdd(c *client.Client, args []string) error {
	fs := newFlagSet("project library add")
	name := fs.String("name", "", "Entry name (default: derived from the path)")
	format := fs.String("format", "", "Output format (table|json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() < 2 {
		return usageError(fs, "foreman project library add: expected <project-id> and at least one <path>")
	}
	if err := checkLibraryFormat(fs, "add", *format); err != nil {
		return err
	}

	plan, err := planLibraryUpload(fs.Args()[1:])
	if err != nil {
		return fmt.Errorf("foreman project library add: %w", err)
	}

	return sendLibraryUpload(c, "POST", libraryBase(fs.Arg(0)), *name, *format, plan)
}

func projectLibraryReplace(c *client.Client, args []string) error {
	fs := newFlagSet("project library replace")
	name := fs.String("name", "", "New entry name (default: keep the current name)")
	format := fs.String("format", "", "Output format (table|json)")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() < 3 {
		return usageError(fs, "foreman project library replace: expected <project-id>, <entry-id> and at least one <path>")
	}
	if err := checkLibraryFormat(fs, "replace", *format); err != nil {
		return err
	}

	plan, err := planLibraryUpload(fs.Args()[2:])
	if err != nil {
		return fmt.Errorf("foreman project library replace: %w", err)
	}

	path := client.JoinPath(libraryBase(fs.Arg(0)), url.PathEscape(fs.Arg(1)))
	return sendLibraryUpload(c, "PUT", path, *name, *format, plan)
}

func projectLibraryRemove(c *client.Client, args []string) error {
	fs := newFlagSet("project library remove")
	if err := fs.parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return usageError(fs, "foreman project library remove: expected <project-id> and <entry-id>")
	}

	path := client.JoinPath(libraryBase(fs.Arg(0)), url.PathEscape(fs.Arg(1)))
	if err := c.DeleteJSON(path, nil); err != nil {
		return err
	}

	_, err := fmt.Fprintf(os.Stdout, "removed library entry %s\n", fs.Arg(1))
	return err
}

func sendLibraryUpload(c *client.Client, method, path, name, format string, plan libraryUploadPlan) error {
	fields := map[string]string{}
	if name == "" && method == "POST" {
		name = plan.defaultName
	}
	if plan.kind == "folder" {
		fields["kind"] = "folder"
	}
	if name != "" {
		fields["name"] = name
	}

	var out struct {
		Entry   map[string]any      `json:"entry"`
		Skipped []map[string]string `json:"skipped"`
	}
	if err := c.SendMultipart(method, path, fields, plan.files, &out); err != nil {
		return err
	}

	skipped := append(plan.skipped, out.Skipped...)
	if format == "json" {
		return printJSON(map[string]any{"entry": out.Entry, "skipped": skipped})
	}

	fmt.Printf("%s library entry %s (%s): %v files, %v bytes\n",
		map[string]string{"POST": "added", "PUT": "replaced"}[method],
		getStr(out.Entry, "entry_id"), getStr(out.Entry, "name"), out.Entry["file_count"], out.Entry["bytes"])
	for _, s := range skipped {
		fmt.Printf("skipped %s (%s)\n", s["path"], s["reason"])
	}
	return nil
}

// planLibraryUpload decides what to upload. One directory is a folder add; anything
// else is a list of files.
func planLibraryUpload(paths []string) (libraryUploadPlan, error) {
	if len(paths) == 1 {
		info, err := os.Stat(paths[0])
		if err != nil {
			return libraryUploadPlan{}, err
		}
		if info.IsDir() {
			return planLibraryFolder(paths[0])
		}
	}

	if len(paths) > libraryMaxFilesPerAdd {
		return libraryUploadPlan{}, fmt.Errorf("at most %d files per add (got %d)", libraryMaxFilesPerAdd, len(paths))
	}

	seen := map[string]bool{}
	plan := libraryUploadPlan{kind: "file"}
	var total int64
	for _, p := range paths {
		info, err := os.Lstat(p)
		if err != nil {
			return libraryUploadPlan{}, err
		}
		if !info.Mode().IsRegular() {
			return libraryUploadPlan{}, fmt.Errorf("%s is not a regular file (pass one folder, or regular files)", p)
		}
		if info.Size() > libraryMaxFileBytes {
			return libraryUploadPlan{}, fmt.Errorf("%s is %d bytes; the per-file limit is %d", p, info.Size(), libraryMaxFileBytes)
		}
		base := filepath.Base(p)
		if seen[base] {
			return libraryUploadPlan{}, fmt.Errorf("two files are named %q; rename one", base)
		}
		seen[base] = true
		total += info.Size()
		if total > libraryUploadMaxBytes {
			return libraryUploadPlan{}, fmt.Errorf("these files add up to more than %d bytes, the limit for one add per request (split them across several adds)", int64(libraryUploadMaxBytes))
		}
		plan.files = append(plan.files, client.UploadFile{Name: base, Path: p})
	}
	return plan, nil
}

// planLibraryFolder walks root depth-first in sorted order with the server's folder
// rules and returns the first folderMaxFiles eligible files within folderMaxBytes.
func planLibraryFolder(root string) (libraryUploadPlan, error) {
	plan := libraryUploadPlan{kind: "folder"}
	if abs, err := filepath.Abs(root); err == nil {
		plan.defaultName = filepath.Base(abs)
	}
	var candidates []client.UploadFile
	var sizes []int64

	err := walkLibraryDir(root, "", &plan, &candidates, &sizes)
	if err != nil {
		return plan, err
	}

	var total int64
	closed := false
	for i, f := range candidates {
		switch {
		case len(plan.files) >= libraryFolderMaxFiles:
			plan.skipped = append(plan.skipped, map[string]string{"path": f.Name, "reason": "folder_file_cap"})
		case closed || total+sizes[i] > libraryFolderMaxBytes:
			closed = true
			plan.skipped = append(plan.skipped, map[string]string{"path": f.Name, "reason": "folder_byte_budget"})
		default:
			total += sizes[i]
			plan.files = append(plan.files, f)
		}
	}

	if len(plan.files) == 0 {
		return plan, fmt.Errorf("folder %s has no eligible files", root)
	}
	return plan, nil
}

func walkLibraryDir(root, rel string, plan *libraryUploadPlan, candidates *[]client.UploadFile, sizes *[]int64) error {
	dir := filepath.Join(root, rel)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })

	skip := func(path, reason string) {
		plan.skipped = append(plan.skipped, map[string]string{"path": path, "reason": reason})
	}

	for _, e := range entries {
		name := e.Name()
		relPath := filepath.ToSlash(filepath.Join(rel, name))
		info, err := os.Lstat(filepath.Join(dir, name))
		if err != nil {
			return err
		}

		switch {
		case info.Mode()&os.ModeSymlink != 0:
			skip(relPath, "symlink")
		case info.IsDir():
			switch {
			case strings.HasPrefix(name, "."):
				skip(relPath, "hidden")
			case name == "node_modules":
				skip(relPath, "node_modules")
			default:
				if err := walkLibraryDir(root, filepath.Join(rel, name), plan, candidates, sizes); err != nil {
					return err
				}
			}
		case !info.Mode().IsRegular():
			skip(relPath, "not_regular")
		case strings.HasPrefix(name, "."):
			skip(relPath, "hidden")
		case info.Size() > libraryFolderSkipFile:
			skip(relPath, "over_30mb")
		default:
			*candidates = append(*candidates, client.UploadFile{Name: relPath, Path: filepath.Join(dir, name)})
			*sizes = append(*sizes, info.Size())
		}
	}
	return nil
}
