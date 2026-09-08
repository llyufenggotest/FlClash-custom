package main

import (
	"fmt"
	"strings"
	"testing"

	shadowsocks "github.com/metacubex/sing-shadowsocks2"
)

const viewTurboCipher = "chacha20-ietf-poly1305"

// The deployed ViewTurbo subscription uses exactly "#vt" as its password.
func TestViewTurboWrapperIsLinkedIntoCoreModule(t *testing.T) {
	method, err := shadowsocks.CreateMethod(viewTurboCipher, shadowsocks.MethodOptions{
		Password: "#vt",
	})
	if err != nil {
		t.Fatalf("CreateMethod(%s) with #vt failed: %v", viewTurboCipher, err)
	}

	typeName := fmt.Sprintf("%T", method)
	if !strings.Contains(typeName, "viewTurbo") {
		t.Fatalf(
			"ViewTurbo wrapper is not linked into the core module: got %s; "+
				"core/go.mod must replace sing-shadowsocks2 with ./sing-shadowsocks2",
			typeName,
		)
	}
}

// Ordinary Shadowsocks shares CreateMethod and must remain unchanged.
func TestNonViewTurboPasswordKeepsUpstreamMethod(t *testing.T) {
	method, err := shadowsocks.CreateMethod(viewTurboCipher, shadowsocks.MethodOptions{
		Password: "an-ordinary-shadowsocks-password",
	})
	if err != nil {
		t.Fatalf("CreateMethod(%s) with a plain password failed: %v", viewTurboCipher, err)
	}

	typeName := fmt.Sprintf("%T", method)
	if strings.Contains(typeName, "viewTurbo") {
		t.Fatalf("plain Shadowsocks must not use ViewTurbo transport, got %s", typeName)
	}
}
