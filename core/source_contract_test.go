package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func readRepoFile(t *testing.T, path string) string {
	t.Helper()
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve test source path")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(filename), path))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func functionSource(t *testing.T, source, signature string) string {
	t.Helper()
	start := strings.Index(source, signature)
	if start < 0 {
		t.Fatalf("missing function %s", signature)
	}
	brace := strings.Index(source[start:], "{")
	if brace < 0 {
		t.Fatalf("missing function body %s", signature)
	}
	brace += start
	depth := 0
	for i := brace; i < len(source); i++ {
		switch source[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return source[start : i+1]
			}
		}
	}
	t.Fatalf("unterminated function %s", signature)
	return ""
}
