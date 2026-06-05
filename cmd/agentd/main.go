package main

import (
	"context"
	"encoding/json"
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
	agentsetup "github.com/gaixiaotongxue/codex-ipad-agent/internal/setup"
)

var version = "0.1.0"

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

	switch cmd {
	case "version":
		fmt.Println(version)
		return nil
	case "setup":
		return runSetup(args)
	case "pair":
		return runPair(args)
	case "doctor":
		return runDoctor(args)
	case "serve":
		cfg, registry, checker, err := loadRuntimeConfig(args, false)
		if err != nil {
			return err
		}
		return serve(cfg, registry, checker)
	default:
		return fmt.Errorf("未知命令 %q，可用命令：setup、pair、serve、doctor、version", cmd)
	}
}

func runSetup(args []string) error {
	fs := flag.NewFlagSet("setup", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	scanRoot := fs.String("scan-root", "", "项目扫描根目录，默认优先使用 ~/code，其次使用当前目录")
	listen := fs.String("listen", "", "agentd 监听地址，默认优先绑定 Tailscale IP")
	appServerListen := fs.String("app-server-listen", "", "本机 Codex app-server WebSocket 地址")
	force := fs.Bool("force", false, "覆盖已有配置并重新生成 token")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	result, err := agentsetup.Run(context.Background(), agentsetup.Options{
		ConfigPath:      *configPath,
		ScanRoot:        *scanRoot,
		Listen:          *listen,
		AppServerListen: *appServerListen,
		Force:           *force,
	})
	if err != nil {
		return err
	}
	if *asJSON {
		return printJSON(result)
	}
	printSetupResult(os.Stdout, result)
	return nil
}

func runPair(args []string) error {
	fs := flag.NewFlagSet("pair", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	result, err := agentsetup.Pair(context.Background(), *configPath)
	if err != nil {
		return err
	}
	if *asJSON {
		return printJSON(result)
	}
	printPairResult(os.Stdout, result)
	return nil
}

func runDoctor(args []string) error {
	checkPort := false
	asJSON := false
	_, _, checker, err := loadRuntimeConfig(args, true, func(fs *flag.FlagSet) {
		fs.BoolVar(&checkPort, "check-port", false, "检查当前配置端口是否可监听")
		fs.BoolVar(&asJSON, "json", false, "只输出 JSON")
	})
	if err != nil {
		return err
	}
	results := checker.Run(context.Background(), checkPort)
	if asJSON {
		if err := printJSON(results); err != nil {
			return err
		}
	} else {
		doctor.Print(os.Stdout, results)
	}
	if !results.OK {
		return fmt.Errorf("doctor 检查未通过")
	}
	return nil
}

func loadRuntimeConfig(args []string, forDoctor bool, configure ...func(*flag.FlagSet)) (config.Config, *projects.Registry, *doctor.Checker, error) {
	fs := flag.NewFlagSet(args[0], flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	for _, fn := range configure {
		fn(fs)
	}
	if err := fs.Parse(args[1:]); err != nil {
		return config.Config{}, nil, nil, err
	}
	var (
		cfg config.Config
		err error
	)
	if forDoctor {
		cfg, err = config.LoadForDoctor(*configPath)
	} else {
		cfg, err = config.Load(*configPath)
	}
	if err != nil {
		return config.Config{}, nil, nil, err
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		return config.Config{}, nil, nil, err
	}
	checker := doctor.NewChecker(version, cfg, registry)
	return cfg, registry, checker, nil
}

func serve(cfg config.Config, registry *projects.Registry, checker *doctor.Checker) error {
	manager := session.NewManager(session.Options{
		CodexBin:     cfg.Codex.Bin,
		DefaultArgs:  cfg.Codex.DefaultArgs,
		Env:          cfg.Codex.Env,
		OutputBuffer: cfg.Session.OutputBufferBytes,
	})
	var appServerWSProcess *appserver.ManagedWebSocketProcess
	if cfg.AppServer.Transport != "ws" {
		return fmt.Errorf("当前 iPad 链路只支持 app_server.transport=ws")
	}
	if strings.TrimSpace(cfg.AppServer.Listen) == "" {
		return fmt.Errorf("app_server.listen 未配置，无法启用 app-server gateway")
	}
	if cfg.AppServer.Managed {
		process, err := startManagedAppServerWebSocket(cfg)
		if err != nil {
			return err
		}
		appServerWSProcess = process
		log.Printf("agentd managed app-server ws upstream=%s", cfg.AppServer.Listen)
	} else {
		log.Printf("agentd app-server ws upstream=%s", cfg.AppServer.Listen)
	}

	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           httpapi.NewRouterWithRuntime(cfg, registry, manager, checker, version, nil),
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
		shutdownServeResources(manager, appServerWSProcess)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return server.Shutdown(ctx)
	case err := <-errCh:
		if err == http.ErrServerClosed {
			return nil
		}
		shutdownServeResources(manager, appServerWSProcess)
		return err
	}
}

func shutdownServeResources(manager *session.Manager, appServerWSProcess *appserver.ManagedWebSocketProcess) {
	// HTTP 端口绑定失败或收到退出信号时，都必须回收托管子进程，避免孤儿进程继续占用 app-server 端口。
	manager.Shutdown()
	if appServerWSProcess != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_ = appServerWSProcess.Shutdown(ctx)
		cancel()
	}
}

func startManagedAppServerWebSocket(cfg config.Config) (*appserver.ManagedWebSocketProcess, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return appserver.StartManagedWebSocket(ctx, appserver.ManagedWebSocketOptions{
		CodexBin:    cfg.Codex.Bin,
		Env:         cfg.Codex.Env,
		Listen:      cfg.AppServer.Listen,
		WSTokenFile: cfg.AppServer.WSTokenFile,
	})
}

func printJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func printSetupResult(w *os.File, result agentsetup.Result) {
	if result.Created {
		fmt.Fprintln(w, "agentd setup 完成")
	} else {
		fmt.Fprintln(w, "agentd 配置已存在，未覆盖")
	}
	fmt.Fprintf(w, "\n配置文件：%s\n", result.ConfigPath)
	fmt.Fprintf(w, "项目扫描：%s\n", result.ScanRoot)
	fmt.Fprintf(w, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(w, "Token：%s\n", result.Token)
	fmt.Fprintf(w, "配对链接：%s\n", result.PairURL)
	if result.AppServerListen != "" {
		fmt.Fprintf(w, "app-server upstream：%s\n", result.AppServerListen)
	}
	if result.AppServerTokenFile != "" {
		fmt.Fprintf(w, "app-server token file：%s\n", result.AppServerTokenFile)
	}
	printWarnings(w, result.Warnings)
	fmt.Fprintln(w, "\n下一步：")
	fmt.Fprintln(w, "  1. agentd doctor --check-port")
	fmt.Fprintln(w, "  2. brew services start codex-ipad-agent")
	fmt.Fprintln(w, "  3. agentd doctor")
	fmt.Fprintln(w, "  4. iPad App 打开设置，填入上面的 Endpoint 和 Token，或打开配对链接")
}

func printPairResult(w *os.File, result agentsetup.Result) {
	fmt.Fprintf(w, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(w, "Token：%s\n", result.Token)
	fmt.Fprintf(w, "配对链接：%s\n", result.PairURL)
	printWarnings(w, result.Warnings)
}

func printWarnings(w *os.File, warnings []string) {
	for _, warning := range warnings {
		fmt.Fprintf(w, "警告：%s\n", warning)
	}
}
