package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

const (
	ruleGenerationManifestVersion = 2
	ruleGenerationManifestMaxSize = 1 << 20
	// Without explicit consumer leases, retain unreferenced generations for a
	// grace period so a config path handed out immediately before a publish is
	// not removed under an active reader.
	ruleGenerationGCGracePeriod = 24 * time.Hour
)

var ruleGenerationPublishLocks sync.Map
var ruleGenerationTestHook func(string) error

type PublishRuleGenerationParams struct {
	ProfileID   int64                    `json:"profile-id"`
	Fingerprint string                   `json:"fingerprint"`
	Generation  string                   `json:"generation"`
	StagingPath string                   `json:"staging-path"`
	ConfigPath  string                   `json:"config-path"`
	Artifacts   []RuleGenerationArtifact `json:"artifacts"`
}

type RuleGenerationArtifact struct {
	Name      string `json:"name"`
	RawPath   string `json:"raw-path"`
	RawSHA256 string `json:"raw-sha256"`
	MRSPath   string `json:"mrs-path,omitempty"`
	MRSSHA256 string `json:"mrs-sha256,omitempty"`
}

type RuleGenerationResult struct {
	Generation string `json:"generation"`
	ConfigPath string `json:"config-path"`
}

type ruleGenerationEntry struct {
	ProfileID    int64                             `json:"profile_id"`
	Fingerprint  string                            `json:"fingerprint"`
	ConfigPath   string                            `json:"config_path"`
	ConfigSHA256 string                            `json:"config_sha256"`
	Artifacts    map[string]RuleGenerationArtifact `json:"artifacts"`
}

type ruleGenerationManifest struct {
	Version  int                            `json:"version"`
	Current  string                         `json:"current"`
	Previous string                         `json:"previous,omitempty"`
	Entries  map[string]ruleGenerationEntry `json:"entries"`
}

func rulePrewarmRoot() string { return filepath.Join(C.Path.HomeDir(), "prewarm") }

func handlePublishRuleGeneration(params *PublishRuleGenerationParams) (RuleGenerationResult, error) {
	if !isInit.Load() {
		return RuleGenerationResult{}, errors.New("not initialized")
	}
	if params.ProfileID <= 0 || !isSHA256(params.Fingerprint) || !isSHA256(params.Generation) {
		return RuleGenerationResult{}, errors.New("invalid rule generation identity")
	}
	profileRoot := filepath.Join(rulePrewarmRoot(), fmt.Sprint(params.ProfileID))
	lockValue, _ := ruleGenerationPublishLocks.LoadOrStore(profileRoot, &sync.Mutex{})
	lock := lockValue.(*sync.Mutex)
	lock.Lock()
	defer lock.Unlock()
	stagingRoot := filepath.Join(profileRoot, "staging")
	generationsRoot := filepath.Join(profileRoot, "generations")
	finalRoot := filepath.Join(generationsRoot, params.Generation)
	if !pathWithin(params.StagingPath, stagingRoot) || !pathWithin(params.ConfigPath, params.StagingPath) {
		return RuleGenerationResult{}, errors.New("unsafe rule generation staging path")
	}
	if err := rejectLinkedComponents(profileRoot, true); err != nil {
		return RuleGenerationResult{}, fmt.Errorf("unsafe rule generation root: %w", err)
	}
	if err := rejectLinkedComponents(params.StagingPath, true); err != nil && !os.IsNotExist(err) {
		return RuleGenerationResult{}, fmt.Errorf("unsafe rule generation staging path: %w", err)
	}

	finalExists := false
	if info, err := os.Lstat(finalRoot); err == nil {
		if linked, linkErr := isReparsePoint(finalRoot, info); linkErr != nil {
			return RuleGenerationResult{}, linkErr
		} else if linked || !info.IsDir() {
			return RuleGenerationResult{}, errors.New("unsafe existing generation")
		}
		if err := rejectLinkedComponents(finalRoot, false); err != nil {
			return RuleGenerationResult{}, fmt.Errorf("unsafe existing generation: %w", err)
		}
		finalExists = true
	} else if !os.IsNotExist(err) {
		return RuleGenerationResult{}, err
	}

	artifacts := make(map[string]RuleGenerationArtifact, len(params.Artifacts))
	for _, artifact := range params.Artifacts {
		if artifact.Name == "" || artifacts[artifact.Name].Name != "" || !pathWithin(artifact.RawPath, params.StagingPath) {
			return RuleGenerationResult{}, fmt.Errorf("invalid rule artifact %q", artifact.Name)
		}
		if !finalExists {
			if err := rejectLinkedComponents(artifact.RawPath, false); err != nil {
				return RuleGenerationResult{}, fmt.Errorf("rule artifact %q raw path: %w", artifact.Name, err)
			}
			if err := validateRegularDigest(artifact.RawPath, artifact.RawSHA256); err != nil {
				return RuleGenerationResult{}, fmt.Errorf("rule artifact %q raw: %w", artifact.Name, err)
			}
		}
		if artifact.MRSPath != "" {
			if !pathWithin(artifact.MRSPath, params.StagingPath) {
				return RuleGenerationResult{}, fmt.Errorf("unsafe MRS path for %q", artifact.Name)
			}
			if !finalExists {
				if err := rejectLinkedComponents(artifact.MRSPath, false); err != nil {
					return RuleGenerationResult{}, fmt.Errorf("rule artifact %q MRS path: %w", artifact.Name, err)
				}
				if err := validateRegularDigest(artifact.MRSPath, artifact.MRSSHA256); err != nil {
					return RuleGenerationResult{}, fmt.Errorf("rule artifact %q MRS: %w", artifact.Name, err)
				}
			}
		}
		artifacts[artifact.Name] = artifact
	}

	rebase := func(path string) string {
		rel, _ := filepath.Rel(params.StagingPath, path)
		return filepath.Join(finalRoot, rel)
	}
	configPath := params.ConfigPath
	if finalExists {
		configPath = rebase(configPath)
	}
	if err := rejectLinkedComponents(configPath, false); err != nil {
		return RuleGenerationResult{}, fmt.Errorf("prepared config path: %w", err)
	}
	configSHA, err := regularFileSHA256(configPath)
	if err != nil {
		return RuleGenerationResult{}, fmt.Errorf("prepared config: %w", err)
	}
	entry := ruleGenerationEntry{ProfileID: params.ProfileID, Fingerprint: strings.ToLower(params.Fingerprint), ConfigPath: rebase(params.ConfigPath), ConfigSHA256: configSHA, Artifacts: map[string]RuleGenerationArtifact{}}
	for name, artifact := range artifacts {
		artifact.RawPath = rebase(artifact.RawPath)
		if artifact.MRSPath != "" {
			artifact.MRSPath = rebase(artifact.MRSPath)
		}
		entry.Artifacts[name] = artifact
	}

	if finalExists {
		if err := validateRuleGenerationEntry(params.Generation, entry); err != nil {
			return RuleGenerationResult{}, fmt.Errorf("existing immutable generation mismatch: %w", err)
		}
	} else {
		if err := syncTree(params.StagingPath); err != nil {
			return RuleGenerationResult{}, err
		}
		if err := os.MkdirAll(generationsRoot, 0755); err != nil {
			return RuleGenerationResult{}, err
		}
		if err := rejectLinkedComponents(generationsRoot, false); err != nil {
			return RuleGenerationResult{}, fmt.Errorf("unsafe generations root: %w", err)
		}
		if err := os.Rename(params.StagingPath, finalRoot); err != nil {
			return RuleGenerationResult{}, err
		}
		if err := syncDirectory(generationsRoot); err != nil {
			return RuleGenerationResult{}, err
		}
	}
	manifestPath := filepath.Join(profileRoot, "manifest.json")
	manifest := ruleGenerationManifest{Version: ruleGenerationManifestVersion, Entries: map[string]ruleGenerationEntry{}}
	if old, err := readRuleGenerationManifest(manifestPath); err == nil {
		manifest = old
	}
	oldCurrent := manifest.Current
	manifest.Version = ruleGenerationManifestVersion
	manifest.Current = params.Generation
	if oldCurrent != "" && oldCurrent != params.Generation {
		manifest.Previous = oldCurrent
	}
	manifest.Entries[params.Generation] = entry
	for id := range manifest.Entries {
		if id != manifest.Current && id != manifest.Previous {
			delete(manifest.Entries, id)
		}
	}
	if ruleGenerationTestHook != nil {
		if err := ruleGenerationTestHook("before-manifest-write"); err != nil {
			return RuleGenerationResult{}, err
		}
	}
	if err := writeRuleGenerationManifest(manifestPath, manifest); err != nil {
		return RuleGenerationResult{}, err
	}
	// The manifest is authoritative after its atomic rename. Cleanup is best
	// effort: failures must not roll back or obscure the published generation,
	// and a later publish will retry the same unreferenced directories.
	_ = garbageCollectRuleGenerations(generationsRoot, manifest)
	return RuleGenerationResult{Generation: params.Generation, ConfigPath: entry.ConfigPath}, nil
}

func garbageCollectRuleGenerations(root string, manifest ruleGenerationManifest) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	cutoff := time.Now().Add(-ruleGenerationGCGracePeriod)
	for _, entry := range entries {
		id := entry.Name()
		if id == manifest.Current || id == manifest.Previous || !isSHA256(id) {
			continue
		}
		path := filepath.Join(root, id)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		linked, err := isReparsePoint(path, info)
		if err != nil {
			return err
		}
		if linked || !info.IsDir() || info.ModTime().After(cutoff) {
			continue
		}
		if err := rejectLinkedComponents(path, false); err != nil {
			return err
		}
		if ruleGenerationTestHook != nil {
			if err := ruleGenerationTestHook("before-generation-remove"); err != nil {
				return err
			}
		}
		if err := os.RemoveAll(path); err != nil {
			return err
		}
	}
	return nil
}

func handleGetPreparedRuleGeneration(profileID int64, fingerprint string) (RuleGenerationResult, error) {
	if !isInit.Load() {
		return RuleGenerationResult{}, errors.New("not initialized")
	}
	if profileID <= 0 || !isSHA256(fingerprint) {
		return RuleGenerationResult{}, nil
	}
	manifest, err := readRuleGenerationManifest(filepath.Join(rulePrewarmRoot(), fmt.Sprint(profileID), "manifest.json"))
	if err != nil {
		return RuleGenerationResult{}, nil
	}
	for _, id := range []string{manifest.Current, manifest.Previous} {
		entry, ok := manifest.Entries[id]
		if !ok || !strings.EqualFold(entry.Fingerprint, fingerprint) {
			continue
		}
		if err := validateRuleGenerationEntry(id, entry); err != nil {
			continue
		}
		return RuleGenerationResult{Generation: id, ConfigPath: entry.ConfigPath}, nil
	}
	return RuleGenerationResult{}, nil
}

func validateRuleGenerationEntry(id string, entry ruleGenerationEntry) error {
	root := filepath.Join(rulePrewarmRoot(), fmt.Sprint(entry.ProfileID), "generations", id)
	if !pathWithin(entry.ConfigPath, root) {
		return errors.New("unsafe config path")
	}
	if err := validateRegularDigest(entry.ConfigPath, entry.ConfigSHA256); err != nil {
		return err
	}
	for _, artifact := range entry.Artifacts {
		if !pathWithin(artifact.RawPath, root) {
			return errors.New("unsafe raw path")
		}
		if err := validateRegularDigest(artifact.RawPath, artifact.RawSHA256); err != nil {
			return err
		}
		if artifact.MRSPath != "" {
			if !pathWithin(artifact.MRSPath, root) {
				return errors.New("unsafe MRS path")
			}
			if err := validateRegularDigest(artifact.MRSPath, artifact.MRSSHA256); err != nil {
				return err
			}
		}
	}
	return nil
}

func readRuleGenerationManifest(path string) (ruleGenerationManifest, error) {
	file, err := os.Open(path)
	if err != nil {
		return ruleGenerationManifest{}, err
	}
	defer file.Close()
	buf, err := io.ReadAll(io.LimitReader(file, ruleGenerationManifestMaxSize+1))
	if err != nil {
		return ruleGenerationManifest{}, err
	}
	if len(buf) > ruleGenerationManifestMaxSize {
		return ruleGenerationManifest{}, errors.New("rule manifest too large")
	}
	var manifest ruleGenerationManifest
	if err := json.Unmarshal(buf, &manifest); err != nil {
		return ruleGenerationManifest{}, err
	}
	if manifest.Version != ruleGenerationManifestVersion || manifest.Entries == nil || len(manifest.Entries) > 2 {
		return ruleGenerationManifest{}, errors.New("invalid rule manifest")
	}
	for _, id := range []string{manifest.Current, manifest.Previous} {
		if id != "" {
			if _, ok := manifest.Entries[id]; !ok {
				return ruleGenerationManifest{}, errors.New("manifest entry missing")
			}
		}
	}
	return manifest, nil
}

func writeRuleGenerationManifest(path string, manifest ruleGenerationManifest) error {
	buf, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	if len(buf) > ruleGenerationManifestMaxSize {
		return errors.New("rule manifest too large")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "manifest.*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err = tmp.Write(buf); err == nil {
		err = tmp.Sync()
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

func pathWithin(path, root string) bool {
	ap, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	ar, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(ar, ap)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

func isSHA256(value string) bool {
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}
func regularFileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("not a regular file")
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}
func validateRegularDigest(path, want string) error {
	if err := rejectLinkedComponents(path, false); err != nil {
		return err
	}
	got, err := regularFileSHA256(path)
	if err != nil {
		return err
	}
	if !strings.EqualFold(got, want) {
		return errors.New("digest mismatch")
	}
	return nil
}

func rejectLinkedComponents(path string, allowMissing bool) error {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	volume := filepath.VolumeName(absolute)
	remainder := strings.TrimPrefix(absolute, volume)
	current := volume + string(filepath.Separator)
	for _, component := range strings.Split(strings.Trim(remainder, string(filepath.Separator)), string(filepath.Separator)) {
		if component == "" {
			continue
		}
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if err != nil {
			if allowMissing && os.IsNotExist(err) {
				return nil
			}
			return err
		}
		linked, err := isReparsePoint(current, info)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || linked {
			return errors.New("symlink or reparse point component")
		}
	}
	return nil
}
func syncTree(root string) error {
	var files []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return err
	}
	sort.Strings(files)
	for _, path := range files {
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		err = file.Sync()
		file.Close()
		if err != nil && runtime.GOOS != "windows" {
			return err
		}
	}
	return syncDirectory(root)
}
