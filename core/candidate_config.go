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

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
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
	entry, ok := manifest.Entries[parts[2]]
	isActive := parts[2] == manifest.Current || parts[2] == manifest.Previous
	if ok && isActive && filepath.Clean(entry.ConfigPath) == path {
		if entry.ProfileID != profileID {
			return "", nil, errors.New("candidate config profile does not match generation path")
		}
		if err := validateRuleGenerationEntry(parts[2], entry); err != nil {
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

func validateStagedConfigAtPath(params *ValidateStagedConfigParams) error {
	if params == nil || params.ProfileID <= 0 || params.StagingPath == "" || params.CandidateConfigPath == "" {
		return errors.New("invalid staged config arguments")
	}
	prewarmRoot := filepath.Join(C.Path.HomeDir(), "prewarm")
	stagingRoot := filepath.Join(prewarmRoot, strconv.FormatInt(params.ProfileID, 10), "staging")
	staging := filepath.Clean(params.StagingPath)
	candidate := filepath.Clean(params.CandidateConfigPath)
	relStaging, err := filepath.Rel(stagingRoot, staging)
	if err != nil {
		return err
	}
	stagingParts := strings.Split(relStaging, string(filepath.Separator))
	if len(stagingParts) != 1 || stagingParts[0] == "." || stagingParts[0] == "" || !strings.HasPrefix(stagingParts[0], "download_") {
		return errors.New("staged config path is not in a preparation directory")
	}
	if !pathWithin(staging, stagingRoot) || staging == stagingRoot || !pathWithin(candidate, staging) || candidate == staging || filepath.Dir(candidate) != staging || filepath.Base(candidate) != "config.yaml" {
		return errors.New("staged config path is outside its preparation scope")
	}
	if err := rejectLinkedComponentsWithinRoot(candidate, prewarmRoot, false); err != nil {
		return fmt.Errorf("unsafe staged config path: %w", err)
	}
	info, err := os.Lstat(candidate)
	if err != nil {
		return err
	}
	linked, err := isReparsePoint(candidate, info)
	if err != nil {
		return err
	}
	if linked || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return errors.New("staged config is not a regular file")
	}
	data, err := os.ReadFile(candidate)
	if err != nil {
		return err
	}
	raw, err := config.UnmarshalRawConfig(data)
	if err != nil {
		return err
	}
	for kind, providers := range map[string]map[string]map[string]any{
		"proxy": raw.ProxyProvider,
		"rule":  raw.RuleProvider,
	} {
		for name, provider := range providers {
			if provider["type"] != "file" {
				return fmt.Errorf("%s provider %q is not local-only", kind, name)
			}
			for _, forbidden := range []string{"url", "proxy", "interval", "size-limit"} {
				if _, ok := provider[forbidden]; ok {
					return fmt.Errorf("%s provider %q retains forbidden field %q", kind, name, forbidden)
				}
			}
			path, ok := provider["path"].(string)
			if !ok || path == "" || !filepath.IsAbs(path) {
				return fmt.Errorf("%s provider %q has no absolute local path", kind, name)
			}
			cleanPath := filepath.Clean(path)
			stagingGenerationRoot := filepath.Clean(filepath.Join(staging, "..", ".."))
			if !pathWithin(cleanPath, staging) && !pathWithin(cleanPath, stagingGenerationRoot) {
				return fmt.Errorf("%s provider %q path is outside managed generation", kind, name)
			}
		}
	}
	if _, err := executor.ParseWithBytes(data); err != nil {
		return err
	}
	return nil
}
