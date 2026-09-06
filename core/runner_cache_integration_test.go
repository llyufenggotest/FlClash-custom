package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/metacubex/bbolt"
	C "github.com/metacubex/mihomo/constant"
)

// This exercises the actual mihomo path join and the actual pinned bbolt,
// without booting the core or consuming its sync.Once cache singleton.
func TestRunnerCachePersistenceAndLockIsolation(t *testing.T) {
	root := t.TempDir()
	private := filepath.Join(root, "Containers", "Data", "Application", "install")
	shared := filepath.Join(root, "Containers", "Shared", "AppGroup", "group")
	for _, dir := range []string{private, shared} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	name, err := runnerCacheFileName(shared, private)
	if err != nil {
		t.Fatal(err)
	}
	C.SetHomeDir(shared)
	C.SetCacheFileName(name)
	t.Cleanup(func() { C.SetCacheFileName("") })
	path := filepath.Clean(C.Path.Cache())
	want := filepath.Join(private, "Library", "Application Support", "RunnerCore", "cache-app.db")
	resolvedDir, err := filepath.EvalSymlinks(filepath.Dir(want))
	if err != nil {
		t.Fatal(err)
	}
	want = filepath.Join(resolvedDir, "cache-app.db")
	if path != want {
		t.Fatalf("cache=%q want=%q", path, want)
	}
	db, err := bbolt.Open(path, 0600, &bbolt.Options{Timeout: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.Update(func(tx *bbolt.Tx) error {
		b, err := tx.CreateBucketIfNotExists([]byte("test"))
		if err != nil {
			return err
		}
		return b.Put([]byte("key"), []byte("persisted"))
	}); err != nil {
		t.Fatal(err)
	}
	// A separate open must contend while the Runner DB remains alive.
	other, err := bbolt.Open(path, 0600, &bbolt.Options{Timeout: 100 * time.Millisecond})
	if other != nil {
		other.Close()
	}
	if err != bbolt.ErrTimeout {
		t.Fatalf("expected retained exclusive lock, got %v", err)
	}
	C.SetCacheFileName("")
	if filepath.Clean(C.Path.Cache()) != filepath.Join(shared, "cache.db") {
		t.Fatal("NE canonical path changed")
	}
	ne, err := bbolt.Open(C.Path.Cache(), 0600, &bbolt.Options{Timeout: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	ne.Close()
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db, err = bbolt.Open(path, 0600, &bbolt.Options{Timeout: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.View(func(tx *bbolt.Tx) error {
		b := tx.Bucket([]byte("test"))
		if b == nil || string(b.Get([]byte("key"))) != "persisted" {
			t.Error("cache persistence lost")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	t.Logf("cache=%s retained-lock=verified independent-NE-open=verified persistence=verified", path)
}
