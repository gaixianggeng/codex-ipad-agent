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

	"github.com/gaixiaotongxue/codex-ipad-agent/internal/appserver"
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
	var runtime httpapi.SessionRuntime = httpapi.NewPTYSessionRuntime(registry, manager)
	var appServerProcess *appserver.ManagedProcess
	if cfg.Runtime.Type == "codex_app_server" {
		process, appRuntime, err := startAppServerRuntime(cfg, registry)
		if err != nil {
			if !cfg.Runtime.FallbackPTY {
				return err
			}
			log.Printf("codex app-server runtime 不可用，回退到 PTY runtime：%v", err)
		} else {
			appServerProcess = process
			runtime = appRuntime
			log.Printf("agentd runtime=codex_app_server transport=stdio managed=true")
		}
	} else {
		log.Printf("agentd runtime=pty fallback=true")
	}

	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           httpapi.NewRouterWithRuntime(cfg, registry, manager, checker, version, runtime),
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
		if appServerProcess != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			_ = appServerProcess.Shutdown(ctx)
			cancel()
		}
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

func startAppServerRuntime(cfg config.Config, registry *projects.Registry) (*appserver.ManagedProcess, *httpapi.CodexAppServerRuntime, error) {
	if cfg.AppServer.Transport != "stdio" || !cfg.AppServer.Managed {
		return nil, nil, fmt.Errorf("当前 MVP 只支持 managed stdio app-server runtime")
	}
	runtime := httpapi.NewCodexAppServerRuntime(registry, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	process, _, err := appserver.StartManaged(ctx, appserver.ManagedOptions{
		CodexBin: cfg.Codex.Bin,
		Env:      cfg.Codex.Env,
		ClientInfo: appserver.ClientInfo{
			Name:    "codex_ipad_agent",
			Title:   "Codex iPad Agent",
			Version: version,
		},
		NotificationBuffer:   1024,
		ServerRequestTimeout: 45 * time.Second,
		OverloadRetries:      2,
		OverloadBackoff:      80 * time.Millisecond,
		ServerRequestHandler: runtime.HandleServerRequest,
	})
	if err != nil {
		return nil, nil, err
	}
	runtime.SetClient(process.Client())
	return process, runtime, nil
}
