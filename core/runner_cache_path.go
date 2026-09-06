package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// runnerCacheFileName returns a relative override because mihomo's Cache joins
// its filename to HomeDir. HomeDir itself must stay shared for NE rule/provider
// artifacts. Never fall back to that shared directory for Runner's bbolt lock.
func runnerCacheFileName(sharedHome, processHome string) (string, error) {
	if !filepath.IsAbs(processHome) || !filepath.IsAbs(sharedHome) {
		return "", fmt.Errorf("cache isolation requires absolute process and core homes")
	}
	privateHome, err := filepath.EvalSymlinks(processHome)
	if err != nil {
		return "", err
	}
	// HOME on iOS identifies the process data container, including on Simulator.
	// Validate the resolved path: a re-sign hook or bad environment must not
	// silently redirect this long-lived lock into an App Group.
	if !strings.Contains(filepath.ToSlash(privateHome), "/Containers/Data/Application/") {
		return "", fmt.Errorf("Runner HOME is not an iOS private data container: %s", privateHome)
	}
	_, err = filepath.EvalSymlinks(sharedHome)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(privateHome, "Library", "Application Support", "RunnerCore")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", err
	}
	within, err := filepath.Rel(privateHome, resolved)
	if err != nil || within == ".." || strings.HasPrefix(within, ".."+string(filepath.Separator)) || filepath.IsAbs(within) {
		return "", fmt.Errorf("Runner cache directory escapes private data container")
	}
	cachePath := filepath.Join(resolved, "cache-app.db")
	if info, err := os.Lstat(cachePath); err == nil {
		if !info.Mode().IsRegular() {
			return "", fmt.Errorf("Runner cache is not a regular file")
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}
	// Use the original HomeDir for Rel too (it may be the /var alias of /private/var).
	// The final joined path must name the resolved private file on disk.
	return filepath.Rel(filepath.Clean(sharedHome), cachePath)
}
