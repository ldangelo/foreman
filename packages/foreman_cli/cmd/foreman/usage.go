package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"strings"

	"github.com/fortium/foreman/packages/foreman_cli/internal/client"
)

type flagSet struct {
	*flag.FlagSet
	output *bytes.Buffer
}

func newFlagSet(name string) *flagSet {
	buf := &bytes.Buffer{}
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(buf)

	return &flagSet{FlagSet: fs, output: buf}
}

func (fs *flagSet) parse(args []string) error {
	if err := fs.FlagSet.Parse(args); err != nil {
		text := strings.TrimRight(fs.output.String(), "\n")
		if errors.Is(err, flag.ErrHelp) {
			return client.NewHelpError(text)
		}
		return client.NewUsageError(text)
	}

	return nil
}

func usageError(fs *flagSet, format string, args ...any) error {
	message := fmt.Sprintf(format, args...)
	if fs.output.Len() == 0 {
		fs.FlagSet.Usage()
	}

	usage := strings.TrimRight(fs.output.String(), "\n")
	if usage == "" {
		return client.NewUsageError(message)
	}

	return client.NewUsageError(message + "\n" + usage)
}

func usageTextError(message, usage string) error {
	usage = strings.TrimSpace(usage)
	if usage == "" {
		return client.NewUsageError(message)
	}

	return client.NewUsageError(message + "\n\n" + usage)
}
