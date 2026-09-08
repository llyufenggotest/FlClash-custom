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
