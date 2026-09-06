package main

import (
	"fmt"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/features"
	"github.com/metacubex/mihomo/tunnel"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSetupConfigPropagatesRuleAdmissionFailure(t *testing.T) {
	if !features.WithLowMemory {
		t.Skip("extension build")
	}
	dir := t.TempDir()
	oldHome := C.Path.HomeDir()
	C.SetHomeDir(dir)
	defer C.SetHomeDir(oldHome)
	oldInit := isInit.Load()
	isInit.Store(true)
	defer isInit.Store(oldInit)
	oldConfig := currentConfig
	oldRules := tunnel.RuleProviders()
	var raw strings.Builder
	for i := 0; i < 10001; i++ {
		fmt.Fprintf(&raw, "DOMAIN,host%d.example\n", i)
	}
	path := filepath.Join(dir, "classical.txt")
	if err := os.WriteFile(path, []byte(raw.String()), 0600); err != nil {
		t.Fatal(err)
	}
	cfg := "rule-providers:\n  required:\n    type: file\n    behavior: classical\n    format: text\n    path: " + filepath.ToSlash(path) + "\nrules:\n  - RULE-SET,required,DIRECT\n  - MATCH,DIRECT\n"
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte(cfg), 0600); err != nil {
		t.Fatal(err)
	}
	result := handleSetupConfig(defaultSetupParams())
	if !strings.Contains(result, "required") || !strings.Contains(result, "10000-rule budget") {
		t.Fatalf("setup falsely succeeded/lost cause: %q", result)
	}
	if currentConfig != oldConfig || tunnel.RuleProviders()["required"] != oldRules["required"] {
		t.Fatal("rejected setup mutated active configuration")
	}
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte("rules: [invalid"), 0600); err != nil {
		t.Fatal(err)
	}
	if result := handleSetupConfig(defaultSetupParams()); result == "" {
		t.Fatal("malformed config started default fallback")
	}
	if currentConfig != oldConfig {
		t.Fatal("parse failure replaced active configuration")
	}
}
