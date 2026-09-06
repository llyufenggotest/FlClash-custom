//go:build !windows

package main

import "os"

func isReparsePoint(string, os.FileInfo) (bool, error) { return false, nil }
