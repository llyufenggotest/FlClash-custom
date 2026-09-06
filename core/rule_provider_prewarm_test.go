package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestPrewarmRuleProviderMethodBuildsArtifact(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "rules.txt")
	if err := os.WriteFile(target, []byte("example.com\n"), 0600); err != nil {
		t.Fatal(err)
	}
	oldInit := isInit.Load()
	isInit.Store(true)
	t.Cleanup(func() { isInit.Store(oldInit) })

	result, err := handlePrewarmRuleProvider(&PrewarmRuleProviderParams{
		Name: "required",
		Definition: map[string]any{
			"type": "http", "url": "https://invalid.example/rules",
			"behavior": "domain", "format": "text", "interval": 1,
		},
		TargetPath: target,
	})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var response struct {
		Path   string `json:"path"`
		Digest string `json:"digest"`
		Count  int    `json:"count"`
	}
	if err := json.Unmarshal(encoded, &response); err != nil {
		t.Fatal(err)
	}
	if response.Path != target || response.Count != 1 || response.Digest == "" {
		t.Fatalf("response=%+v", response)
	}
	if _, err := os.Stat(target + ".mrs"); err != nil {
		t.Fatal(err)
	}
}
