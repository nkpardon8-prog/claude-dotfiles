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

func TestParsePushArgs_OverwriteFlag(t *testing.T) {
	got, err := parsePushArgs([]string{"--overwrite", "./a.txt", "/tmp/b.txt"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Overwrite {
		t.Errorf("overwrite: want true, got false")
	}
	if got.Local != "./a.txt" {
		t.Errorf("local: want ./a.txt, got %q", got.Local)
	}
	if got.Remote != "/tmp/b.txt" {
		t.Errorf("remote: want /tmp/b.txt, got %q", got.Remote)
	}
}

func TestParsePushArgs_NoOverwriteByDefault(t *testing.T) {
	got, err := parsePushArgs([]string{"./a.txt", "/tmp/b.txt"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Overwrite {
		t.Errorf("overwrite: want false (default), got true")
	}
}

func TestParseRunArgs_JSONFlag(t *testing.T) {
	got, err := parseRunArgs([]string{"--json", "echo", "hi"}, true)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.JSON {
		t.Errorf("json: want true, got false")
	}
}
