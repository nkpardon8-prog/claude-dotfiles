package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"macmini-client/internal/redact"
	"macmini-client/internal/transport"
)

// Version is set via -ldflags at build time.
var Version = "dev"

// usage prints the top-level help.
func usage(w io.Writer) {
	fmt.Fprintf(w, `macmini-client — thin HTTP client for macmini-server

Usage:
  macmini-client <command> [flags] [args]

Commands:
  health
  paste <text> | paste -
  push <local> [remote]
  pull <remote> [local]
  run [--timeout=N] [--cwd=PATH] [--idem-key=KEY] <command...>
  run-stream [--timeout=N] [--cwd=PATH] <command...>
  shot [--out=PATH]
  rotate-token
  version
`)
}

// runOpts captures the parsed flags shared between run / run-stream.
type runOpts struct {
	Timeout int
	CWD     string
	IdemKey string
	JSON    bool
	Command string
}

// pushOpts captures parsed args for `push`.
type pushOpts struct {
	Local     string
	Remote    string
	Overwrite bool
}

// pullOpts captures parsed args for `pull`.
type pullOpts struct {
	Remote string
	Local  string
}

// shotOpts captures parsed args for `shot`.
type shotOpts struct {
	Out string
}

// parseRunArgs extracts --timeout / --cwd / --idem-key flags and treats the
// remainder as a single shell command (joined with spaces, mirroring the
// server's `/bin/zsh -lc <command>` contract).
func parseRunArgs(args []string, allowIdem bool) (*runOpts, error) {
	o := &runOpts{}
	rest := []string{}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case strings.HasPrefix(a, "--timeout="):
			n, err := transport.ParseInt(strings.TrimPrefix(a, "--timeout="))
			if err != nil {
				return nil, fmt.Errorf("invalid --timeout: %w", err)
			}
			o.Timeout = n
		case strings.HasPrefix(a, "--cwd="):
			o.CWD = strings.TrimPrefix(a, "--cwd=")
		case strings.HasPrefix(a, "--idem-key="):
			if !allowIdem {
				return nil, errors.New("--idem-key not supported here")
			}
			o.IdemKey = strings.TrimPrefix(a, "--idem-key=")
		case a == "--json":
			o.JSON = true
		case a == "--":
			rest = append(rest, args[i+1:]...)
			i = len(args)
		default:
			rest = append(rest, a)
		}
	}
	if len(rest) == 0 {
		return nil, errors.New("missing <command>")
	}
	o.Command = strings.Join(rest, " ")
	return o, nil
}

// parsePushArgs returns local + remote with the documented default. The
// `--overwrite` flag (presence = true) may appear in any position before the
// positional args.
func parsePushArgs(args []string) (*pushOpts, error) {
	o := &pushOpts{}
	rest := []string{}
	for _, a := range args {
		switch {
		case a == "--overwrite":
			o.Overwrite = true
		default:
			rest = append(rest, a)
		}
	}
	if len(rest) == 0 {
		return nil, errors.New("usage: push [--overwrite] <local> [remote]")
	}
	o.Local = rest[0]
	if len(rest) >= 2 {
		o.Remote = rest[1]
	} else {
		o.Remote = "~/Documents/macmini-skill/" + filepath.Base(o.Local)
	}
	return o, nil
}

func parsePullArgs(args []string) (*pullOpts, error) {
	if len(args) == 0 {
		return nil, errors.New("usage: pull <remote> [local]")
	}
	remote := args[0]
	var local string
	if len(args) >= 2 {
		local = args[1]
	} else {
		local = "./" + filepath.Base(remote)
	}
	return &pullOpts{Remote: remote, Local: local}, nil
}

func parseShotArgs(args []string) *shotOpts {
	o := &shotOpts{}
	for _, a := range args {
		if strings.HasPrefix(a, "--out=") {
			o.Out = strings.TrimPrefix(a, "--out=")
		}
	}
	if o.Out == "" {
		o.Out = fmt.Sprintf("./macmini-shot-%d.png", time.Now().Unix())
	}
	return o
}

// printRunHuman renders a buffered RunResp per the run.md spec:
//
//	$ <command>
//	<stdout>
//	↳ stderr: <stderr>   (only if non-empty)
//	↳ exit: <code> · duration: <Xs>
func printRunHuman(command string, resp *transport.RunResp) {
	fmt.Fprintf(os.Stdout, "$ %s\n", command)
	if resp.Stdout != "" {
		_, _ = io.WriteString(os.Stdout, resp.Stdout)
		if !strings.HasSuffix(resp.Stdout, "\n") {
			_, _ = io.WriteString(os.Stdout, "\n")
		}
	}
	if resp.Stderr != "" {
		lines := strings.Split(strings.TrimRight(resp.Stderr, "\n"), "\n")
		for i, line := range lines {
			if i == 0 {
				fmt.Fprintf(os.Stderr, "↳ stderr: %s\n", line)
			} else {
				fmt.Fprintf(os.Stderr, "         %s\n", line)
			}
		}
	}
	trailer := fmt.Sprintf("↳ exit: %d · duration: %.2fs", resp.ExitCode, resp.DurationSeconds)
	if resp.Truncated {
		trailer += " (truncated)"
	}
	fmt.Fprintln(os.Stderr, trailer)
}

// reportErr scrubs hostname strings before printing and exits with the
// appropriate code (1 = server error, 2 = transport/auth/setup).
func reportErr(err error) int {
	if err == nil {
		return 0
	}
	msg := redact.Scrub(err.Error())
	fmt.Fprintln(os.Stderr, msg)
	var se *transport.ServerError
	if errors.As(err, &se) {
		return 1
	}
	return 2
}

func main() {
	if len(os.Args) < 2 {
		usage(os.Stderr)
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]

	switch cmd {
	case "-h", "--help", "help":
		usage(os.Stdout)
		os.Exit(0)

	case "version":
		fmt.Println(Version)
		os.Exit(0)

	case "health":
		c := transport.New()
		h, err := c.Health()
		if err != nil {
			os.Exit(reportErr(err))
		}
		_ = json.NewEncoder(os.Stdout).Encode(h)
		os.Exit(0)

	case "paste":
		if len(args) == 0 {
			fmt.Fprintln(os.Stderr, "usage: paste <text> | paste -")
			os.Exit(2)
		}
		var text string
		if args[0] == "-" {
			b, err := io.ReadAll(os.Stdin)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(2)
			}
			text = string(b)
		} else {
			text = strings.Join(args, " ")
		}
		c := transport.New()
		if err := c.Paste(text); err != nil {
			os.Exit(reportErr(err))
		}
		os.Exit(0)

	case "push":
		opts, err := parsePushArgs(args)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		c := transport.New()
		resp, err := c.Push(opts.Local, opts.Remote, opts.Overwrite)
		if err != nil {
			os.Exit(reportErr(err))
		}
		_ = json.NewEncoder(os.Stdout).Encode(resp)
		os.Exit(0)

	case "pull":
		opts, err := parsePullArgs(args)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		c := transport.New()
		resp, err := c.Pull(opts.Remote, opts.Local)
		if err != nil {
			os.Exit(reportErr(err))
		}
		_ = json.NewEncoder(os.Stdout).Encode(resp)
		os.Exit(0)

	case "run":
		opts, err := parseRunArgs(args, true)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		c := transport.New()
		resp, err := c.Run(transport.RunRequest{
			Command:        opts.Command,
			CWD:            opts.CWD,
			TimeoutSeconds: opts.Timeout,
			IdempotencyKey: opts.IdemKey,
		})
		if err != nil {
			os.Exit(reportErr(err))
		}
		if opts.JSON {
			_ = json.NewEncoder(os.Stdout).Encode(resp)
			os.Exit(resp.ExitCode)
		}
		printRunHuman(opts.Command, resp)
		os.Exit(resp.ExitCode)

	case "run-stream":
		opts, err := parseRunArgs(args, false)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		c := transport.New()
		result, err := c.RunStream(transport.RunRequest{
			Command:        opts.Command,
			CWD:            opts.CWD,
			TimeoutSeconds: opts.Timeout,
		}, os.Stdout)
		if err != nil {
			os.Exit(reportErr(err))
		}
		if !opts.JSON {
			fmt.Fprintf(os.Stderr, "↳ exit: %d · duration: %.2fs\n",
				result.ExitCode, float64(result.DurationMS)/1000.0)
		}
		os.Exit(result.ExitCode)

	case "shot":
		opts := parseShotArgs(args)
		c := transport.New()
		f, err := os.Create(opts.Out)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		if err := c.Shot(f); err != nil {
			_ = f.Close()
			_ = os.Remove(opts.Out)
			os.Exit(reportErr(err))
		}
		_ = f.Close()
		fmt.Println(opts.Out)
		os.Exit(0)

	case "rotate-token":
		c := transport.New()
		resp, err := c.RotateToken()
		if err != nil {
			os.Exit(reportErr(err))
		}
		fmt.Printf("NEW TOKEN: %s\nFINGERPRINT: %s\nUpdate 1Password (op://<VAULT>/Mac mini CRD/Server Token), then run /load-creds CRD_SERVER_TOKEN.\n",
			resp.NewToken, resp.NewFingerprint)
		os.Exit(0)

	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", cmd)
		usage(os.Stderr)
		os.Exit(2)
	}
}
