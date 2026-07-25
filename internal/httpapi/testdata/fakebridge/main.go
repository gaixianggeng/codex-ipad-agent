// Command fakebridge stands in for alleycat-claude-bridge in gateway tests.
//
// The real bridge serves a Unix socket and multiplexes connections onto
// sessions. Reproducing that in a shell stub is not practical, so this helper
// owns the socket and runs a caller-supplied shell script per connection with
// stdin/stdout wired to it — letting tests keep expressing bridge behaviour as
// the same small line-oriented scripts they used when the bridge spoke stdio.
package main

import (
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
)

func main() {
	body := flag.String("body", "", "path to the shell script serving one connection")
	socket := flag.String("socket", "", "unix socket to listen on")
	flag.Parse()

	if *socket == "" {
		log.Fatal("fakebridge: --socket is required")
	}
	listener, err := net.Listen("unix", *socket)
	if err != nil {
		log.Fatalf("fakebridge: listen: %v", err)
	}
	defer listener.Close()

	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		go serve(conn, *body)
	}
}

func serve(conn net.Conn, body string) {
	defer conn.Close()
	cmd := exec.Command("/bin/sh", body)
	cmd.Stdin = conn
	cmd.Stderr = os.Stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	// Copy rather than assigning conn to cmd.Stdout so the script's output
	// reaches the socket as it is written, without waiting for exit.
	_, _ = io.Copy(conn, stdout)
	_ = cmd.Wait()
}
