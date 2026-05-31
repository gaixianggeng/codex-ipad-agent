package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/config"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/doctor"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/httpapi"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/projects"
	"github.com/gaixiaotongxue/codex-ipad-agent/internal/session"
)

const version = "0.1.0"

func main() {
	if err := run(os.Args); err != nil {
		log.Fatalf("agentd: %v", err)
	}
}

func run(args []string) error {
	cmd := "serve"
	if len(args) > 1 && !strings.HasPrefix(args[1], "-") {
		cmd = args[1]
		args = append([]string{args[0]}, args[2:]...)
	}

	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	configPath := fs.String("config", "config.json", "配置文件路径")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	var cfg config.Config
	var err error
	if cmd == "doctor" {
		cfg, err = config.LoadForDoctor(*configPath)
	} else {
		cfg, err = config.Load(*configPath)
	}
	if err != nil {
		return err
	}

	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		return err
	}

	checker := doctor.NewChecker(version, cfg, registry)
	switch cmd {
	case "doctor":
		results := checker.Run(context.Background(), false)
		doctor.Print(os.Stdout, results)
		if !results.OK {
			return fmt.Errorf("doctor 检查未通过")
		}
		return nil
	case "serve":
		return serve(cfg, registry, checker)
	case "version":
		fmt.Println(version)
		return nil
	default:
		return fmt.Errorf("未知命令 %q，可用命令：serve、doctor、version", cmd)
	}
}

func serve(cfg config.Config, registry *projects.Registry, checker *doctor.Checker) error {
	manager := session.NewManager(session.Options{
		CodexBin:     cfg.Codex.Bin,
		DefaultArgs:  cfg.Codex.DefaultArgs,
		Env:          cfg.Codex.Env,
		OutputBuffer: cfg.Session.OutputBufferBytes,
	})

	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           httpapi.NewRouter(cfg, registry, manager, checker, version),
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("agentd listening on http://%s", cfg.Listen)
		errCh <- server.ListenAndServe()
	}()

	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, os.Interrupt, syscall.SIGTERM)

	select {
	case sig := <-stopCh:
		log.Printf("收到退出信号 %s，正在关闭会话和 HTTP 服务", sig)
		manager.Shutdown()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return server.Shutdown(ctx)
	case err := <-errCh:
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}
