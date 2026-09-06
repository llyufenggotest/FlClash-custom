package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func testDigest(data []byte) string {
	s := sha256.Sum256(data)
	return hex.EncodeToString(s[:])
}

func stageGeneration(t *testing.T, profileID int64, fingerprint, generation, raw string) PublishRuleGenerationParams {
	t.Helper()
	profileRoot := filepath.Join(C.Path.HomeDir(), "prewarm", stringID(profileID))
	stage := filepath.Join(profileRoot, "staging", generation)
	rules := filepath.Join(stage, "rules")
	if err := os.MkdirAll(rules, 0o700); err != nil {
		t.Fatal(err)
	}
	rawPath := filepath.Join(rules, "ads.raw")
	sidecarPath := rawPath + ".mrs"
	configPath := filepath.Join(stage, "config.yaml")
	mrs := "MRS-SC02:" + raw
	config := "rule-providers:\n  ads:\n    type: file\n    path: " + filepath.ToSlash(filepath.Join(profileRoot, "generations", generation, "rules", "ads.raw")) + "\n"
	for path, data := range map[string]string{rawPath: raw, sidecarPath: mrs, configPath: config} {
		if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return PublishRuleGenerationParams{
		ProfileID: profileID, Fingerprint: fingerprint, Generation: generation,
		StagingPath: stage, ConfigPath: configPath,
		Artifacts: []RuleGenerationArtifact{{
			Name: "ads", RawPath: rawPath, MRSPath: sidecarPath,
			RawSHA256: testDigest([]byte(raw)), MRSSHA256: testDigest([]byte(mrs)),
		}},
	}
}

func enableRuleGenerationTests(t *testing.T) {
	t.Helper()
	old := isInit.Load()
	isInit.Store(true)
	t.Cleanup(func() { isInit.Store(old) })
}

func TestPublishRuleGenerationRetainsTwoImmutableReadyEntries(t *testing.T) {
	enableRuleGenerationTests(t)
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	fingerA := strings.Repeat("a", 64)
	fingerB := strings.Repeat("b", 64)
	genA := strings.Repeat("1", 64)
	genB := strings.Repeat("2", 64)

	a := stageGeneration(t, 7, fingerA, genA, "raw-a")
	resultA, err := handlePublishRuleGeneration(&a)
	if err != nil {
		t.Fatal(err)
	}
	b := stageGeneration(t, 7, fingerB, genB, "raw-b")
	resultB, err := handlePublishRuleGeneration(&b)
	if err != nil {
		t.Fatal(err)
	}
	if resultA.Generation != genA || resultB.Generation != genB {
		t.Fatalf("results: %+v %+v", resultA, resultB)
	}
	for _, fingerprint := range []string{fingerA, fingerB} {
		ready, err := handleGetPreparedRuleGeneration(7, fingerprint)
		if err != nil || ready.ConfigPath == "" {
			t.Fatalf("%s not ready: %+v %v", fingerprint, ready, err)
		}
	}
	if got, err := os.ReadFile(filepath.Join(C.Path.HomeDir(), "prewarm", "7", "generations", genA, "rules", "ads.raw")); err != nil || string(got) != "raw-a" {
		t.Fatalf("old generation mutated: %q %v", got, err)
	}
}

func TestPreparedRuleGenerationFallsBackToValidPreviousWithSameFingerprint(t *testing.T) {
	enableRuleGenerationTests(t)
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	fingerprint := strings.Repeat("9", 64)
	previous := strings.Repeat("7", 64)
	current := strings.Repeat("8", 64)

	first := stageGeneration(t, 8, fingerprint, previous, "raw-previous")
	if _, err := handlePublishRuleGeneration(&first); err != nil {
		t.Fatal(err)
	}
	second := stageGeneration(t, 8, fingerprint, current, "raw-current")
	if _, err := handlePublishRuleGeneration(&second); err != nil {
		t.Fatal(err)
	}
	currentRaw := filepath.Join(C.Path.HomeDir(), "prewarm", "8", "generations", current, "rules", "ads.raw")
	if err := os.WriteFile(currentRaw, []byte("corrupt"), 0o600); err != nil {
		t.Fatal(err)
	}

	ready, err := handleGetPreparedRuleGeneration(8, fingerprint)
	if err != nil {
		t.Fatal(err)
	}
	if ready.Generation != previous {
		t.Fatalf("ready generation = %q, want previous %q", ready.Generation, previous)
	}
}

func TestPreparedRuleGenerationFailsClosedOnCorruptArtifact(t *testing.T) {
	enableRuleGenerationTests(t)
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	fingerprint := strings.Repeat("c", 64)
	generation := strings.Repeat("3", 64)
	params := stageGeneration(t, 9, fingerprint, generation, "raw")
	if _, err := handlePublishRuleGeneration(&params); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(C.Path.HomeDir(), "prewarm", "9", "generations", generation, "rules", "ads.raw")
	if err := os.WriteFile(path, []byte("corrupt"), 0o600); err != nil {
		t.Fatal(err)
	}
	ready, err := handleGetPreparedRuleGeneration(9, fingerprint)
	if err != nil {
		t.Fatal(err)
	}
	if ready.Generation != "" || ready.ConfigPath != "" {
		t.Fatalf("corrupt generation reported ready: %+v", ready)
	}
}

func TestPublishRuleGenerationRecoversAfterManifestFailure(t *testing.T) {
	enableRuleGenerationTests(t)
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	fingerprint := strings.Repeat("d", 64)
	generation := strings.Repeat("4", 64)
	params := stageGeneration(t, 11, fingerprint, generation, "raw-retry")

	failed := false
	ruleGenerationTestHook = func(point string) error {
		if point == "before-manifest-write" && !failed {
			failed = true
			return errors.New("injected manifest failure")
		}
		return nil
	}
	t.Cleanup(func() { ruleGenerationTestHook = nil })
	if _, err := handlePublishRuleGeneration(&params); err == nil || !strings.Contains(err.Error(), "injected") {
		t.Fatalf("first publish error = %v", err)
	}
	if _, err := os.Stat(filepath.Join(C.Path.HomeDir(), "prewarm", "11", "generations", generation)); err != nil {
		t.Fatalf("generation was not durably published before injected failure: %v", err)
	}

	result, err := handlePublishRuleGeneration(&params)
	if err != nil {
		t.Fatalf("retry did not recover existing generation: %v", err)
	}
	if result.Generation != generation {
		t.Fatalf("retry result = %+v", result)
	}
	ready, err := handleGetPreparedRuleGeneration(11, fingerprint)
	if err != nil || ready.Generation != generation {
		t.Fatalf("recovered generation not ready: %+v %v", ready, err)
	}
	if _, err := handlePublishRuleGeneration(&params); err != nil {
		t.Fatalf("committed retry is not idempotent: %v", err)
	}
}

func TestPublishRuleGenerationGarbageCollectionFailureIsRetryable(t *testing.T) {
	enableRuleGenerationTests(t)
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	fingerprint := strings.Repeat("a", 64)
	generations := []string{strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)}
	for i := 0; i < 2; i++ {
		params := stageGeneration(t, 30, fingerprint, generations[i], fmt.Sprintf("raw-%d", i))
		if _, err := handlePublishRuleGeneration(&params); err != nil {
			t.Fatal(err)
		}
	}
	obsolete := filepath.Join(C.Path.HomeDir(), "prewarm", "30", "generations", generations[0])
	old := time.Now().Add(-2 * ruleGenerationGCGracePeriod)
	if err := os.Chtimes(obsolete, old, old); err != nil {
		t.Fatal(err)
	}

	failed := false
	ruleGenerationTestHook = func(point string) error {
		if point == "before-generation-remove" && !failed {
			failed = true
			return errors.New("injected cleanup failure")
		}
		return nil
	}
	t.Cleanup(func() { ruleGenerationTestHook = nil })
	third := stageGeneration(t, 30, fingerprint, generations[2], "raw-2")
	if _, err := handlePublishRuleGeneration(&third); err != nil {
		t.Fatalf("cleanup failure failed published generation: %v", err)
	}
	manifest, err := readRuleGenerationManifest(filepath.Join(C.Path.HomeDir(), "prewarm", "30", "manifest.json"))
	if err != nil || manifest.Current != generations[2] || manifest.Previous != generations[1] {
		t.Fatalf("published manifest changed by cleanup failure: %+v %v", manifest, err)
	}
	if _, err := os.Stat(obsolete); err != nil {
		t.Fatalf("failed cleanup removed obsolete generation: %v", err)
	}

	ruleGenerationTestHook = nil
	if _, err := handlePublishRuleGeneration(&third); err != nil {
		t.Fatalf("retry publish failed: %v", err)
	}
	if _, err := os.Stat(obsolete); !os.IsNotExist(err) {
		t.Fatalf("obsolete generation survived retry: %v", err)
	}
}

func TestPublishRuleGenerationGarbageCollectionBoundsOldDirectories(t *testing.T) {
	enableRuleGenerationTests(t)
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	fingerprint := strings.Repeat("d", 64)
	var last PublishRuleGenerationParams
	for i := 1; i <= 8; i++ {
		generation := fmt.Sprintf("%064x", i)
		last = stageGeneration(t, 31, fingerprint, generation, fmt.Sprintf("raw-%d", i))
		if _, err := handlePublishRuleGeneration(&last); err != nil {
			t.Fatal(err)
		}
		manifest, err := readRuleGenerationManifest(filepath.Join(C.Path.HomeDir(), "prewarm", "31", "manifest.json"))
		if err != nil {
			t.Fatal(err)
		}
		root := filepath.Join(C.Path.HomeDir(), "prewarm", "31", "generations")
		entries, err := os.ReadDir(root)
		if err != nil {
			t.Fatal(err)
		}
		old := time.Now().Add(-2 * ruleGenerationGCGracePeriod)
		for _, entry := range entries {
			if entry.Name() != manifest.Current && entry.Name() != manifest.Previous {
				path := filepath.Join(root, entry.Name())
				if err := os.Chtimes(path, old, old); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	if _, err := handlePublishRuleGeneration(&last); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(C.Path.HomeDir(), "prewarm", "31", "generations")
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		t.Fatalf("generation directories = %v, want exactly current and previous", names)
	}
}

func TestPublishRuleGenerationRejectsSymlinkComponents(t *testing.T) {
	enableRuleGenerationTests(t)
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	fingerprint := strings.Repeat("e", 64)
	generation := strings.Repeat("5", 64)
	outside := t.TempDir()

	tests := []struct {
		name string
		link func(t *testing.T, p *PublishRuleGenerationParams)
	}{
		{"staging", func(t *testing.T, p *PublishRuleGenerationParams) {
			if err := os.RemoveAll(p.StagingPath); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(outside, p.StagingPath); err != nil {
				t.Fatal(err)
			}
		}},
		{"config", func(t *testing.T, p *PublishRuleGenerationParams) {
			if err := os.Remove(p.ConfigPath); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(outside, "config.yaml")
			if err := os.WriteFile(target, []byte("outside"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, p.ConfigPath); err != nil {
				t.Fatal(err)
			}
		}},
		{"artifact-parent", func(t *testing.T, p *PublishRuleGenerationParams) {
			rules := filepath.Dir(p.Artifacts[0].RawPath)
			if err := os.RemoveAll(rules); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(outside, rules); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for i, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := stageGeneration(t, int64(20+i), fingerprint, generation, "raw-link")
			tc.link(t, &p)
			if _, err := handlePublishRuleGeneration(&p); err == nil {
				t.Fatal("unsafe linked path was accepted")
			}
		})
	}
}

func TestPublishRuleGenerationConfigDigestUsesExactBytes(t *testing.T) {
	enableRuleGenerationTests(t)
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(t.TempDir())
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	fingerprint := strings.Repeat("f", 64)
	generation := strings.Repeat("6", 64)
	params := stageGeneration(t, 14, fingerprint, generation, "raw")
	configBytes, err := os.ReadFile(params.ConfigPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := handlePublishRuleGeneration(&params); err != nil {
		t.Fatal(err)
	}
	manifest, err := readRuleGenerationManifest(filepath.Join(C.Path.HomeDir(), "prewarm", "14", "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	entry := manifest.Entries[generation]
	if entry.Fingerprint != fingerprint || entry.ConfigSHA256 != testDigest(configBytes) {
		t.Fatalf("identity mismatch: fingerprint=%q config-sha=%q", entry.Fingerprint, entry.ConfigSHA256)
	}
}

func stringID(value int64) string { return fmt.Sprint(value) }
