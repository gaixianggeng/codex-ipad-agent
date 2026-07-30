package main

import (
	"bytes"
	"crypto/sha256"
	"testing"
)

func TestNormalizeLineEndingsKeepsContractHashStable(t *testing.T) {
	t.Parallel()

	lf := []byte("{\n  \"current_revision\": 2\n}\n")
	crlf := []byte("{\r\n  \"current_revision\": 2\r\n}\r\n")

	if got := normalizeLineEndings(crlf); !bytes.Equal(got, lf) {
		t.Fatalf("normalizeLineEndings() = %q, want %q", got, lf)
	}
	if sha256.Sum256(normalizeLineEndings(lf)) != sha256.Sum256(normalizeLineEndings(crlf)) {
		t.Fatal("LF 与 CRLF 契约应生成相同的来源哈希")
	}
}

func TestNormalizeLineEndingsMakesGeneratedSnapshotPortable(t *testing.T) {
	t.Parallel()

	generated := []byte("// generated\nconst revision = 2\n")
	windowsCheckout := []byte("// generated\r\nconst revision = 2\r\n")

	if !bytes.Equal(normalizeLineEndings(generated), normalizeLineEndings(windowsCheckout)) {
		t.Fatal("Windows checkout 不应触发生成快照漂移")
	}
}
