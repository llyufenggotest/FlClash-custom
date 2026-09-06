package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestShutdownRetiresRuleProvidersWithoutChangingStopListener(t *testing.T) {
	executorSource := readRepoFile(t, filepath.Join("mihomo", "hub", "executor", "executor.go"))
	shutdown := functionSource(t, executorSource, "func Shutdown()")
	if !strings.Contains(shutdown, "tunnel.RetireRuleProviders()") {
		t.Fatal("executor shutdown does not retire active rule providers")
	}

	hubSource := readRepoFile(t, "hub.go")
	stopListener := functionSource(t, hubSource, "func handleStopListener()")
	if strings.Contains(stopListener, "RetireRuleProviders") || strings.Contains(stopListener, "executor.Shutdown") {
		t.Fatal("listener-only stop retires resources owned by the running core")
	}
}

func functionSource(t *testing.T, source, signature string) string {
	t.Helper()
	start := strings.Index(source, signature)
	if start < 0 {
		t.Fatalf("missing function %q", signature)
	}
	body := source[start:]
	end := strings.Index(body, "\n}")
	if end < 0 {
		t.Fatalf("unterminated function %q", signature)
	}
	return body[:end+2]
}
