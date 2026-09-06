package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

const testGenerationID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func writeCandidateConfig(t *testing.T, home, body string) string {
	t.Helper()
	path := filepath.Join(home, "prewarm", "7", "generations", testGenerationID, "config.yaml")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	digest, err := regularFileSHA256(path)
	if err != nil {
		t.Fatal(err)
	}
	manifest := ruleGenerationManifest{
		Version: ruleGenerationManifestVersion,
		Current: testGenerationID,
		Entries: map[string]ruleGenerationEntry{
			testGenerationID: {
				ProfileID:    7,
				ConfigPath:   path,
				ConfigSHA256: digest,
				Artifacts:    map[string]RuleGenerationArtifact{},
			},
		},
	}
	if err := writeRuleGenerationManifest(filepath.Join(home, "prewarm", "7", "manifest.json"), manifest); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSetupConfigAdmitsCandidateInsteadOfFormalConfig(t *testing.T) {
	home, err := os.MkdirTemp("", "candidate-config-admission-")
	if err != nil {
		t.Fatal(err)
	}
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(home)
	defer C.SetHomeDir(oldHome)
	oldInit := isInit.Load()
	isInit.Store(true)
	defer isInit.Store(oldInit)

	formal := []byte("rules: [invalid")
	formalPath := filepath.Join(home, "config.yaml")
	if err = os.WriteFile(formalPath, formal, 0o600); err != nil {
		t.Fatal(err)
	}
	candidate := writeCandidateConfig(t, home, "mode: direct\nrules:\n  - MATCH,DIRECT\n")
	params := &ValidateCandidateConfigParams{CandidateConfigPath: candidate}
	if result := handleValidateCandidateConfig(params); result != "" {
		t.Fatalf("candidate admission failed: %s", result)
	}
	got, err := os.ReadFile(formalPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(formal) {
		t.Fatalf("Runner admission changed formal config: got %q want %q", got, formal)
	}
}

func TestValidateCandidateConfigOnlyAdmitsPublishedArtifact(t *testing.T) {
	home := t.TempDir()
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(home)
	defer C.SetHomeDir(oldHome)

	candidate := writeCandidateConfig(t, home, "rules: [invalid")
	oldInit := isInit.Load()
	isInit.Store(true)
	defer isInit.Store(oldInit)

	params := &ValidateCandidateConfigParams{CandidateConfigPath: candidate}
	if result := handleValidateCandidateConfig(params); result != "" {
		t.Fatalf("published artifact admission performed semantic parsing: %s", result)
	}
}

func TestCandidateConfigPathRejectsUnsafeFiles(t *testing.T) {
	home := t.TempDir()
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(home)
	defer C.SetHomeDir(oldHome)
	valid := writeCandidateConfig(t, home, "mode: direct\n")
	relative, err := filepath.Rel(home, valid)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := validateCandidateConfigPath(relative); err != nil || got != valid {
		t.Fatalf("valid relative candidate rejected: got %q err %v", got, err)
	}
	outside := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(outside, []byte("mode: direct\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	cases := map[string]string{
		"outside prewarm":      outside,
		"generation directory": filepath.Dir(valid),
		"staging file":         filepath.Join(home, "prewarm", "7", "staging", testGenerationID, "config.yaml"),
		"invalid profile":      filepath.Join(home, "prewarm", "profile", "generations", testGenerationID, "config.yaml"),
	}
	for name, path := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := validateCandidateConfigPath(path); err == nil {
				t.Fatalf("unsafe candidate accepted: %s", path)
			}
		})
	}

	if runtime.GOOS != "windows" {
		link := filepath.Join(filepath.Dir(valid), "linked.yaml")
		if err := os.Symlink(outside, link); err != nil {
			t.Fatal(err)
		}
		if _, err := validateCandidateConfigPath(link); err == nil || !strings.Contains(err.Error(), "symlink") {
			t.Fatalf("candidate symlink was not rejected: %v", err)
		}
	}
}

func TestRejectedCandidateDoesNotFallBackToFormalConfig(t *testing.T) {
	home := t.TempDir()
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(home)
	defer C.SetHomeDir(oldHome)
	oldInit := isInit.Load()
	isInit.Store(true)
	defer isInit.Store(oldInit)

	formal := []byte("mode: direct\nrules:\n  - MATCH,DIRECT\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), formal, 0o600); err != nil {
		t.Fatal(err)
	}
	candidate := writeCandidateConfig(t, home, "mode: direct\n")
	if err := os.WriteFile(candidate, []byte("mode: global\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	params := &ValidateCandidateConfigParams{CandidateConfigPath: candidate}
	if result := handleValidateCandidateConfig(params); result == "" {
		t.Fatal("digest-mismatched candidate silently fell back to formal config")
	}
	got, err := os.ReadFile(filepath.Join(home, "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(formal) {
		t.Fatal("rejected candidate changed formal config bytes")
	}
}
