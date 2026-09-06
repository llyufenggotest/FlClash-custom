package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	C "github.com/metacubex/mihomo/constant"
)

func validateCandidateConfigPath(candidate string) (string, error) {
	path, _, err := readValidatedCandidateConfig(candidate)
	return path, err
}

func readValidatedCandidateConfig(candidate string) (string, []byte, error) {
	if candidate == "" {
		return "", nil, errors.New("candidate config path is empty")
	}
	path := candidate
	if !filepath.IsAbs(path) {
		path = filepath.Join(C.Path.HomeDir(), path)
	}
	path = filepath.Clean(path)
	prewarmRoot := filepath.Join(C.Path.HomeDir(), "prewarm")
	if !pathWithin(path, prewarmRoot) {
		return "", nil, errors.New("candidate config path is outside prewarm root")
	}
	rel, err := filepath.Rel(prewarmRoot, path)
	if err != nil {
		return "", nil, err
	}
	parts := strings.Split(rel, string(filepath.Separator))
	if len(parts) < 4 {
		return "", nil, errors.New("candidate config path is not in a published generation")
	}
	profileID, profileErr := strconv.ParseInt(parts[0], 10, 64)
	if profileErr != nil || profileID <= 0 || parts[1] != "generations" || !isSHA256(parts[2]) {
		return "", nil, errors.New("candidate config path is not in a published generation")
	}
	if err := rejectLinkedComponentsWithinRoot(path, prewarmRoot, false); err != nil {
		return "", nil, fmt.Errorf("unsafe candidate config path: %w", err)
	}
	preOpenInfo, err := os.Lstat(path)
	if err != nil {
		return "", nil, err
	}
	preOpenLinked, err := isReparsePoint(path, preOpenInfo)
	if err != nil {
		return "", nil, err
	}
	if preOpenLinked || preOpenInfo.Mode()&os.ModeSymlink != 0 || !preOpenInfo.Mode().IsRegular() {
		return "", nil, errors.New("candidate config is not a regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", nil, err
	}
	if !os.SameFile(preOpenInfo, info) {
		return "", nil, errors.New("candidate config changed while opening")
	}
	linked, err := isReparsePoint(path, info)
	if err != nil {
		return "", nil, err
	}
	if linked || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", nil, errors.New("candidate config is not a regular file")
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return "", nil, err
	}
	manifest, err := readRuleGenerationManifest(filepath.Join(prewarmRoot, parts[0], "manifest.json"))
	if err != nil {
		return "", nil, fmt.Errorf("candidate generation manifest: %w", err)
	}
	for _, id := range []string{manifest.Current, manifest.Previous} {
		entry, ok := manifest.Entries[id]
		if !ok || id != parts[2] || filepath.Clean(entry.ConfigPath) != path {
			continue
		}
		if entry.ProfileID != profileID {
			return "", nil, errors.New("candidate config profile does not match generation path")
		}
		if err := validateRuleGenerationEntry(id, entry); err != nil {
			return "", nil, fmt.Errorf("candidate generation validation: %w", err)
		}
		digest := sha256.Sum256(data)
		if !strings.EqualFold(hex.EncodeToString(digest[:]), entry.ConfigSHA256) {
			return "", nil, errors.New("candidate config changed during validation")
		}
		return path, data, nil
	}
	return "", nil, errors.New("candidate config is not a published generation")
}

func validateCandidateConfigAtPath(candidate string) error {
	_, _, err := readValidatedCandidateConfig(candidate)
	return err
}
