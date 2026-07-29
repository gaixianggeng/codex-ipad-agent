//go:build windows

package httpapi

import (
	"net"
	"testing"
)

func TestPrepareClaudeBridgeEndpointUsesLoopbackTCP(t *testing.T) {
	network, address, args, err := prepareClaudeBridgeEndpoint(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if network != "tcp" {
		t.Fatalf("network = %q, want tcp", network)
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatalf("invalid address %q: %v", address, err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() || port == "" {
		t.Fatalf("address = %q, want a loopback endpoint", address)
	}
	if len(args) != 2 || args[0] != "--tcp-listen" || args[1] != address {
		t.Fatalf("args = %#v, want [--tcp-listen %s]", args, address)
	}
}
