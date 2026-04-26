package main

import "testing"

func TestParseRunArgs_FlagsAndCommand(t *testing.T) {
	got, err := parseRunArgs([]string{"--timeout=5", "--cwd=/tmp", "echo", "hi"}, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Timeout != 5 {
		t.Errorf("timeout: want 5, got %d", got.Timeout)
	}
	if got.CWD != "/tmp" {
		t.Errorf("cwd: want /tmp, got %q", got.CWD)
	}
	if got.Command != "echo hi" {
		t.Errorf("command: want %q, got %q", "echo hi", got.Command)
	}
	if got.IdemKey != "" {
		t.Errorf("idem-key: want empty, got %q", got.IdemKey)
	}
}

func TestParseRunArgs_IdemKey(t *testing.T) {
	got, err := parseRunArgs([]string{"--idem-key=abc", "echo", "hi"}, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.IdemKey != "abc" {
		t.Errorf("idem-key: want abc, got %q", got.IdemKey)
	}
}

func TestParseRunArgs_RejectsIdemWhenDisallowed(t *testing.T) {
	_, err := parseRunArgs([]string{"--idem-key=abc", "echo"}, false)
	if err == nil {
		t.Fatalf("expected error when --idem-key is disallowed")
	}
}

func TestParseRunArgs_MissingCommand(t *testing.T) {
	_, err := parseRunArgs([]string{"--timeout=5"}, true)
	if err == nil {
		t.Fatalf("expected error for missing command")
	}
}

func TestParsePushArgs_DefaultsRemote(t *testing.T) {
	got, err := parsePushArgs([]string{"file.txt"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Local != "file.txt" {
		t.Errorf("local: want file.txt, got %q", got.Local)
	}
	want := "~/Documents/macmini-skill/file.txt"
	if got.Remote != want {
		t.Errorf("remote: want %q, got %q", want, got.Remote)
	}
}

func TestParsePushArgs_ExplicitRemote(t *testing.T) {
	got, err := parsePushArgs([]string{"/abs/path/x.bin", "/tmp/macmini-skill/y.bin"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Remote != "/tmp/macmini-skill/y.bin" {
		t.Errorf("remote: got %q", got.Remote)
	}
}

func TestParsePullArgs_DefaultsLocal(t *testing.T) {
	got, err := parsePullArgs([]string{"~/Documents/macmini-skill/foo.log"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Local != "./foo.log" {
		t.Errorf("local: want ./foo.log, got %q", got.Local)
	}
}
