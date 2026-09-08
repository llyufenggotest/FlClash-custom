package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunnerCachePath(t *testing.T) {
	root := t.TempDir()
	private := filepath.Join(root, "Containers", "Data", "Application", "test-install")
	shared := filepath.Join(root, "Containers", "Shared", "AppGroup", "group")
	if err := os.MkdirAll(private, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(shared, 0700); err != nil {
		t.Fatal(err)
	}
	name, err := runnerCacheFileName(shared, private)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(resolvedExpectedParent(t, private), "Library", "Application Support", "RunnerCore", "cache-app.db")
	if got := filepath.Join(shared, name); got != want {
		t.Fatalf("cache = %q, want %q", got, want)
	}
	if info, err := os.Stat(filepath.Dir(want)); err != nil || !info.IsDir() {
		t.Fatalf("directory missing: %v", err)
	}
	again, err := runnerCacheFileName(shared, private)
	if err != nil || again != name {
		t.Fatalf("repeat init changed path: %q %v", again, err)
	}
}

func resolvedExpectedParent(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}

func TestResolvedExpectedParentCanonicalizesAlias(t *testing.T) {
	root := t.TempDir()
	realParent := filepath.Join(root, "real")
	if err := os.Mkdir(realParent, 0700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(realParent, alias); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if got, want := resolvedExpectedParent(t, alias), resolvedExpectedParent(t, realParent); got != want {
		t.Fatalf("resolved parent = %q, want %q", got, want)
	}
}

func TestRunnerCacheRejectsSymlinkEscape(t *testing.T) {
	root := t.TempDir()
	private := filepath.Join(root, "Containers", "Data", "Application", "install")
	support := filepath.Join(private, "Library", "Application Support")
	shared := filepath.Join(root, "shared")
	for _, dir := range []string{support, shared} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(shared, filepath.Join(support, "RunnerCore")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if _, err := runnerCacheFileName(shared, private); err == nil {
		t.Fatal("accepted shared symlink target")
	}
}

func TestRunnerCacheWiringContract(t *testing.T) {
	hub, err := os.ReadFile("hub.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(hub)
	if !strings.Contains(text, "features.IOS && !features.WithLowMemory") || !strings.Contains(text, "runnerCacheFileName(params.HomeDir, processHome)") || !strings.Contains(text, "constant.SetHomeDir(params.HomeDir)") {
		t.Fatal("platform isolation/shared home contract missing")
	}
	dart, err := os.ReadFile("../lib/common/path.dart")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(dart), "if (split(relativePath).first == 'RunnerCore')") {
		t.Fatal("private cache sync exclusion missing")
	}
}

func TestRunnerCacheRejectsNonPrivateHome(t *testing.T) {
	for _, home := range []string{"", ".", t.TempDir(), "/private/var/mobile/Containers/Shared/AppGroup/id"} {
		if _, err := runnerCacheFileName(t.TempDir(), home); err == nil {
			t.Fatalf("accepted non-private home %q", home)
		}
	}
}
