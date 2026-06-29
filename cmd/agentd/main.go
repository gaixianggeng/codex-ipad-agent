package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/session"
	agentsetup "github.com/gaixianggeng/mimi-remote/internal/setup"
	"github.com/skip2/go-qrcode"
)

var version = "0.1.0"

func main() {
	if err := run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "错误：%v\n", err)
		os.Exit(1)
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
	case "up":
		return runUp(args)
	case "start":
		return runStart(args)
	case "restart":
		return runRestart(args)
	case "status":
		return runStatus(args)
	case "logs":
		return runLogs(args)
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
		return fmt.Errorf("未知命令 %q，可用命令：up、setup、start、restart、status、logs、pair、serve、doctor、version", cmd)
	}
}

func runSetup(args []string) error {
	fs := flag.NewFlagSet("setup", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	scanRoot := fs.String("scan-root", "", "项目扫描根目录，默认优先使用 ~/code，其次使用当前目录")
	browseRoot := fs.String("browse-root", "", "iPad 目录浏览/打开 workspace 的授权根目录，默认使用用户 Home")
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
		BrowseRoot:      *browseRoot,
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

func runUp(args []string) error {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	scanRoot := fs.String("scan-root", "", "项目扫描根目录，默认优先使用 ~/code，其次使用当前目录")
	browseRoot := fs.String("browse-root", "", "iPad 目录浏览/打开 workspace 的授权根目录，默认使用用户 Home")
	listen := fs.String("listen", "", "agentd 监听地址，默认优先绑定 Tailscale IP")
	appServerListen := fs.String("app-server-listen", "", "本机 Codex app-server WebSocket 地址")
	waitTimeout := fs.Duration("wait", 10*time.Second, "等待后台服务健康检查时间，设置 0 可跳过")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	if !*asJSON {
		fmt.Fprintln(os.Stdout, "正在准备 Mimi Mac 助手...")
	}
	result, err := agentsetup.Run(context.Background(), agentsetup.Options{
		ConfigPath:      *configPath,
		ScanRoot:        *scanRoot,
		BrowseRoot:      *browseRoot,
		Listen:          *listen,
		AppServerListen: *appServerListen,
	})
	if err != nil {
		return err
	}
	if err := ensureCodexCLIAvailable(result.ConfigPath); err != nil {
		return err
	}

	serviceStdout := io.Writer(os.Stdout)
	serviceStderr := io.Writer(os.Stderr)
	if *asJSON {
		serviceStdout = io.Discard
		serviceStderr = io.Discard
	}
	if err := runBrewService("start", serviceStdout, serviceStderr); err != nil {
		return fmt.Errorf("%w\n\n安装 Homebrew 后请重新运行：agentd up\n排查环境可以运行：agentd doctor --fix", err)
	}

	serviceOK := true
	serviceError := ""
	if err := waitForServiceHealth(context.Background(), result.Endpoint, *waitTimeout); err != nil {
		serviceOK = false
		serviceError = err.Error()
		if *asJSON {
			return printJSON(map[string]any{
				"result":        result,
				"service_ok":    serviceOK,
				"service_error": serviceError,
			})
		}
		return fmt.Errorf("Mimi Mac 助手还没有启动成功，暂时不要扫码。\n\n原因：%v\n下一步：\n  agentd doctor --fix\n  agentd logs", err)
	} else if *waitTimeout > 0 {
		if *asJSON {
			return printJSON(map[string]any{
				"result":     result,
				"service_ok": serviceOK,
			})
		}
		fmt.Fprintln(os.Stdout, "Mimi Mac 助手已准备好")
	}
	if *asJSON {
		return printJSON(map[string]any{
			"result":     result,
			"service_ok": serviceOK,
		})
	}

	printServeConnection(os.Stdout, result)
	fmt.Fprintln(os.Stdout, "常用命令：")
	fmt.Fprintln(os.Stdout, "  agentd status       查看当前连接状态")
	fmt.Fprintln(os.Stdout, "  agentd pair         刷新配对二维码")
	fmt.Fprintln(os.Stdout, "  agentd doctor --fix 自动检查并修复常见问题")
	return nil
}

func runStart(args []string) error {
	fs := flag.NewFlagSet("start", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	waitTimeout := fs.Duration("wait", 8*time.Second, "等待后台服务健康检查时间，设置 0 可跳过")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	result, err := agentsetup.Pair(context.Background(), *configPath)
	if err != nil {
		return fmt.Errorf("读取连接信息失败，请先执行 agentd setup：%w", err)
	}

	fmt.Fprintln(os.Stdout, "正在启动 Homebrew 后台服务...")
	if err := runBrewService("start", os.Stdout, os.Stderr); err != nil {
		return err
	}

	if err := waitForServiceHealth(context.Background(), result.Endpoint, *waitTimeout); err != nil {
		fmt.Fprintf(os.Stdout, "警告：后台服务已提交，但健康检查未通过：%v\n", err)
	} else if *waitTimeout > 0 {
		fmt.Fprintln(os.Stdout, "agentd 后台服务已启动")
	}
	printServeConnection(os.Stdout, result)
	return nil
}

func runRestart(args []string) error {
	fs := flag.NewFlagSet("restart", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	waitTimeout := fs.Duration("wait", 8*time.Second, "等待后台服务健康检查时间，设置 0 可跳过")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	result, err := agentsetup.Pair(context.Background(), *configPath)
	if err != nil {
		return fmt.Errorf("读取连接信息失败，请先执行 agentd up：%w", err)
	}
	fmt.Fprintln(os.Stdout, "正在重启 Mimi Mac 助手...")
	if err := runBrewService("restart", os.Stdout, os.Stderr); err != nil {
		return err
	}
	if err := waitForServiceHealth(context.Background(), result.Endpoint, *waitTimeout); err != nil {
		fmt.Fprintf(os.Stdout, "警告：后台服务已重启，但健康检查未通过：%v\n", err)
	} else if *waitTimeout > 0 {
		fmt.Fprintln(os.Stdout, "Mimi Mac 助手已重新连接")
	}
	printServeConnection(os.Stdout, result)
	return nil
}

func runStatus(args []string) error {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	configPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	asJSON := fs.Bool("json", false, "输出 JSON")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	cfg, registry, checker, err := loadRuntimeConfigFromPath(*configPath, true)
	if err != nil {
		return err
	}
	result := agentsetup.ResultFromConfig(context.Background(), *configPath, cfg)
	healthErr := waitForServiceHealth(context.Background(), result.Endpoint, time.Second)
	doctorResults := checker.Run(context.Background(), false)
	status := map[string]any{
		"version":      version,
		"endpoint":     result.Endpoint,
		"config_path":  result.ConfigPath,
		"projects":     len(registry.List()),
		"service_ok":   healthErr == nil,
		"doctor_ok":    doctorResults.OK,
		"doctor":       doctorResults,
		"pair_expires": result.PairExpiresAt,
	}
	if healthErr != nil {
		status["service_error"] = healthErr.Error()
	}
	if *asJSON {
		return printJSON(status)
	}

	fmt.Fprintln(os.Stdout, "Mimi Mac 助手状态")
	fmt.Fprintf(os.Stdout, "\n版本：%s\n", version)
	fmt.Fprintf(os.Stdout, "配置：%s\n", result.ConfigPath)
	fmt.Fprintf(os.Stdout, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(os.Stdout, "项目数：%d\n", len(registry.List()))
	if healthErr == nil {
		fmt.Fprintln(os.Stdout, "服务：可连接")
	} else {
		fmt.Fprintf(os.Stdout, "服务：暂时不可连接（%v）\n", healthErr)
	}
	if doctorResults.OK {
		fmt.Fprintln(os.Stdout, "环境：检查通过")
	} else {
		fmt.Fprintln(os.Stdout, "环境：需要处理")
		printDoctorActions(os.Stdout, doctorResults)
	}
	fmt.Fprintln(os.Stdout, "\n下一步：")
	fmt.Fprintln(os.Stdout, "  agentd pair         刷新配对二维码")
	fmt.Fprintln(os.Stdout, "  agentd doctor --fix 自动检查并修复常见问题")
	fmt.Fprintln(os.Stdout, "  agentd logs         查看最近日志")
	return nil
}

func runLogs(args []string) error {
	fs := flag.NewFlagSet("logs", flag.ExitOnError)
	lineCount := fs.Int("n", 120, "显示最近日志行数")
	follow := fs.Bool("f", false, "跟随日志输出")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	path, err := homebrewLogPath()
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stdout, "日志文件：%s\n\n", path)
	if *follow {
		tail, err := exec.LookPath("tail")
		if err != nil {
			return fmt.Errorf("未找到 tail 命令，无法跟随日志：%w", err)
		}
		cmd := exec.Command(tail, "-n", fmt.Sprint(*lineCount), "-f", path)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	}
	lines, err := tailLines(path, *lineCount)
	if err != nil {
		return err
	}
	for _, line := range lines {
		fmt.Fprintln(os.Stdout, line)
	}
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
	fix := false
	configPath := config.DefaultPath()
	fs := flag.NewFlagSet("doctor", flag.ExitOnError)
	fs.StringVar(&configPath, "config", config.DefaultPath(), "配置文件路径")
	fs.BoolVar(&checkPort, "check-port", false, "检查当前配置端口是否可监听")
	fs.BoolVar(&asJSON, "json", false, "只输出 JSON")
	fs.BoolVar(&fix, "fix", false, "自动修复安全的常见问题")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	_, _, checker, err := loadRuntimeConfigFromPath(configPath, true)
	if err != nil {
		if !fix {
			return err
		}
		fixes, repairedChecker, repairedResults, repairErr := rebuildDoctorConfig(context.Background(), configPath, checkPort)
		if repairErr != nil {
			return fmt.Errorf("%v；自动修复也失败：%w", err, repairErr)
		}
		if asJSON {
			return printJSON(map[string]any{"fixes": fixes, "results": repairedResults})
		}
		fmt.Fprintf(os.Stdout, "配置加载失败，已尝试自动修复：%v\n\n", err)
		if len(fixes) > 0 {
			fmt.Fprintln(os.Stdout, "已修复：")
			for _, item := range fixes {
				fmt.Fprintf(os.Stdout, "  OK %s\n", item)
			}
			fmt.Fprintln(os.Stdout)
		}
		doctor.Print(os.Stdout, repairedResults)
		_ = repairedChecker
		if !repairedResults.OK {
			return fmt.Errorf("doctor 检查未通过")
		}
		return nil
	}
	results := checker.Run(context.Background(), checkPort)
	fixes := []string{}
	if fix {
		fixes, checker, results, err = runDoctorFix(context.Background(), configPath, checkPort, results)
		if err != nil {
			return err
		}
	}
	if asJSON {
		payload := any(results)
		if fix {
			payload = map[string]any{"fixes": fixes, "results": results}
		}
		if err := printJSON(payload); err != nil {
			return err
		}
	} else {
		if fix && len(fixes) > 0 {
			fmt.Fprintln(os.Stdout, "已修复：")
			for _, item := range fixes {
				fmt.Fprintf(os.Stdout, "  OK %s\n", item)
			}
			fmt.Fprintln(os.Stdout)
		}
		doctor.Print(os.Stdout, results)
		_ = checker
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

func loadRuntimeConfigFromPath(configPath string, forDoctor bool) (config.Config, *projects.Registry, *doctor.Checker, error) {
	var (
		cfg config.Config
		err error
	)
	if forDoctor {
		cfg, err = config.LoadForDoctor(configPath)
	} else {
		cfg, err = config.Load(configPath)
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

func runDoctorFix(ctx context.Context, configPath string, checkPort bool, current doctor.Results) ([]string, *doctor.Checker, doctor.Results, error) {
	fixes := []string{}
	needsSetup := false
	if _, err := os.Stat(configPath); err != nil {
		if os.IsNotExist(err) {
			needsSetup = true
		} else {
			return nil, nil, current, fmt.Errorf("读取配置状态失败：%w", err)
		}
	}
	if hasFailedCheck(current, "token") || hasFailedCheck(current, "projects") {
		needsSetup = true
	}
	if needsSetup {
		setupFixes, err := forceSetupWithBackup(ctx, configPath)
		if err != nil {
			return nil, nil, current, err
		}
		fixes = append(fixes, setupFixes...)
	}
	_, registry, checker, err := loadRuntimeConfigFromPath(configPath, true)
	if err != nil {
		return nil, nil, current, err
	}
	_ = registry
	return fixes, checker, checker.Run(ctx, checkPort), nil
}

func rebuildDoctorConfig(ctx context.Context, configPath string, checkPort bool) ([]string, *doctor.Checker, doctor.Results, error) {
	fixes, err := forceSetupWithBackup(ctx, configPath)
	if err != nil {
		return nil, nil, doctor.Results{}, err
	}
	_, _, checker, err := loadRuntimeConfigFromPath(configPath, true)
	if err != nil {
		return nil, nil, doctor.Results{}, err
	}
	return fixes, checker, checker.Run(ctx, checkPort), nil
}

func forceSetupWithBackup(ctx context.Context, configPath string) ([]string, error) {
	fixes := []string{}
	if fileExists(configPath) {
		backup, err := backupFile(configPath)
		if err != nil {
			return nil, err
		}
		fixes = append(fixes, "已备份旧配置："+backup)
	}
	if _, err := agentsetup.Run(ctx, agentsetup.Options{ConfigPath: configPath, Force: true}); err != nil {
		return nil, fmt.Errorf("自动生成配置失败：%w", err)
	}
	fixes = append(fixes, "已生成可配对的默认配置")
	return fixes, nil
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

	listener, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		shutdownServeResources(manager, appServerWSProcess)
		return err
	}

	maybePrintServeConnection(os.Stdout, agentsetup.ResultFromConfig(context.Background(), "", cfg))

	errCh := make(chan error, 2)
	go func() {
		log.Printf("agentd listening on http://%s", cfg.Listen)
		errCh <- server.Serve(listener)
	}()
	if appServerWSProcess != nil {
		go func() {
			<-appServerWSProcess.Done()
			errCh <- managedAppServerExitedError(appServerWSProcess)
		}()
	}

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

func managedAppServerExitedError(process *appserver.ManagedWebSocketProcess) error {
	if process == nil {
		return fmt.Errorf("托管 codex app-server WebSocket 已退出")
	}
	exitErr := process.ExitError()
	message := "托管 codex app-server WebSocket 已退出"
	if exitErr != nil {
		message += "：" + exitErr.Error()
	}
	diag := process.Diagnostics()
	if len(diag.StderrTail) > 0 {
		message += "\n最近 stderr：\n  " + strings.Join(diag.StderrTail, "\n  ")
	}
	return fmt.Errorf("%s", message)
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
	if strings.TrimSpace(cfg.AppServer.WSTokenFile) == "" {
		return nil, fmt.Errorf("app_server.ws_token_file 未配置；请运行 agentd setup --force 生成独立 app-server upstream token")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return appserver.StartManagedWebSocket(ctx, appserver.ManagedWebSocketOptions{
		CodexBin:    cfg.Codex.Bin,
		Env:         cfg.Codex.Env,
		Listen:      cfg.AppServer.Listen,
		WSTokenFile: cfg.AppServer.WSTokenFile,
	})
}

func runBrewService(action string, stdout, stderr io.Writer) error {
	brew, err := exec.LookPath("brew")
	if err != nil {
		return fmt.Errorf("未找到 Homebrew；请先在 Mac 安装 Homebrew：https://brew.sh")
	}
	cmd := exec.Command(brew, "services", action, config.AppName)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("执行 brew services %s %s 失败：%w", action, config.AppName, err)
	}
	return nil
}

func printDoctorActions(w io.Writer, results doctor.Results) {
	printedHeader := false
	for _, check := range results.Checks {
		if check.OK {
			continue
		}
		if !printedHeader {
			fmt.Fprintln(w, "\n需要处理：")
			printedHeader = true
		}
		fmt.Fprintf(w, "  ! %s：%s\n", check.Name, check.Message)
		if strings.TrimSpace(check.Fix) != "" {
			fmt.Fprintf(w, "    处理：%s\n", check.Fix)
		}
	}
}

func homebrewLogPath() (string, error) {
	candidates := []string{}
	if brew, err := exec.LookPath("brew"); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if out, err := exec.CommandContext(ctx, brew, "--prefix").Output(); err == nil {
			prefix := strings.TrimSpace(string(out))
			if prefix != "" {
				candidates = append(candidates, filepath.Join(prefix, "var", "log", config.AppName+".log"))
			}
		}
	}
	candidates = append(candidates,
		filepath.Join("/opt/homebrew/var/log", config.AppName+".log"),
		filepath.Join("/usr/local/var/log", config.AppName+".log"),
	)
	for _, path := range candidates {
		if stat, err := os.Stat(path); err == nil && !stat.IsDir() {
			return path, nil
		}
	}
	return "", fmt.Errorf("未找到 Mimi Mac 助手日志文件；请先运行 agentd up，或用 agentd serve 前台调试")
}

func tailLines(path string, count int) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("打开日志文件失败：%w", err)
	}
	defer file.Close()

	if count <= 0 {
		count = 120
	}
	lines := make([]string, 0, count)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1024), 1024*1024)
	for scanner.Scan() {
		if len(lines) == count {
			copy(lines, lines[1:])
			lines[count-1] = scanner.Text()
			continue
		}
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("读取日志文件失败：%w", err)
	}
	return lines, nil
}

func hasFailedCheck(results doctor.Results, name string) bool {
	for _, check := range results.Checks {
		if check.Name == name && !check.OK {
			return true
		}
	}
	return false
}

func backupFile(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("备份配置前读取失败：%w", err)
	}
	backup := fmt.Sprintf("%s.bak-%s", path, time.Now().Format("20060102150405"))
	if err := os.WriteFile(backup, raw, 0o600); err != nil {
		return "", fmt.Errorf("写入配置备份失败：%w", err)
	}
	return backup, nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func printJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

func ensureCodexCLIAvailable(configPath string) error {
	cfg, err := config.LoadForDoctor(configPath)
	if err != nil {
		return fmt.Errorf("读取 Codex 配置失败：%w", err)
	}
	bin := strings.TrimSpace(cfg.Codex.Bin)
	if bin == "" {
		bin = "codex"
	}
	if _, err := exec.LookPath(bin); err != nil {
		return fmt.Errorf("未找到 Codex CLI，Mimi Mac 助手还不能启动。\n\n请先在这台 Mac 安装并登录 Codex，然后重新运行：\n  agentd up")
	}
	return nil
}

func printSetupResult(w io.Writer, result agentsetup.Result) {
	if result.Created {
		fmt.Fprintln(w, "agentd setup 完成")
	} else {
		fmt.Fprintln(w, "agentd 配置已存在，未覆盖")
	}
	fmt.Fprintf(w, "\n配置文件：%s\n", result.ConfigPath)
	fmt.Fprintf(w, "项目扫描：%s\n", result.ScanRoot)
	if result.BrowseRoot != "" {
		fmt.Fprintf(w, "目录浏览授权根：%s\n", result.BrowseRoot)
	}
	fmt.Fprintf(w, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(w, "Token：%s\n", result.Token)
	fmt.Fprintf(w, "连接链接：%s\n", result.ConnectURL)
	fmt.Fprintf(w, "配对链接：%s\n", result.PairURL)
	if result.PairExpiresAt != "" {
		fmt.Fprintf(w, "二维码有效期至：%s\n", result.PairExpiresAt)
	}
	if result.AppServerListen != "" {
		fmt.Fprintf(w, "app-server upstream：%s\n", result.AppServerListen)
	}
	if result.AppServerTokenFile != "" {
		fmt.Fprintf(w, "app-server token file：%s\n", result.AppServerTokenFile)
	}
	printConnectionQRCode(w, result.PairURL)
	printWarnings(w, result.Warnings)
	fmt.Fprintln(w, "\n下一步：")
	fmt.Fprintln(w, "  1. agentd doctor --check-port")
	fmt.Fprintln(w, "  2. agentd start")
	fmt.Fprintln(w, "  3. agentd doctor")
	fmt.Fprintln(w, "  4. iPad App 打开设置，扫码连接；二维码不可用时再手动输入 Endpoint 和 Token")
}

func printPairResult(w io.Writer, result agentsetup.Result) {
	fmt.Fprintf(w, "Endpoint：%s\n", result.Endpoint)
	fmt.Fprintf(w, "Token：%s\n", result.Token)
	fmt.Fprintf(w, "连接链接：%s\n", result.ConnectURL)
	fmt.Fprintf(w, "配对链接：%s\n", result.PairURL)
	if result.PairExpiresAt != "" {
		fmt.Fprintf(w, "二维码有效期至：%s\n", result.PairExpiresAt)
	}
	printConnectionQRCode(w, result.PairURL)
	printWarnings(w, result.Warnings)
}

func printServeConnection(w io.Writer, result agentsetup.Result) {
	printWarnings(w, result.Warnings)
	fmt.Fprintln(w, "\n用 iPad 扫这个二维码连接这台 Mac：")
	printConnectionQRCode(w, result.PairURL)
	if result.PairExpiresAt != "" {
		fmt.Fprintf(w, "二维码 10 分钟内有效，有效期至：%s\n", result.PairExpiresAt)
	}
	fmt.Fprintln(w, "扫不了时，在 iPad 的“高级手动连接”里填写：")
	fmt.Fprintf(w, "  地址：%s\n", result.Endpoint)
	fmt.Fprintf(w, "  访问码：%s\n", result.Token)
	fmt.Fprintln(w)
}

func maybePrintServeConnection(w *os.File, result agentsetup.Result) {
	if !isTerminalOutput(w) {
		return
	}
	printServeConnection(w, result)
}

func isTerminalOutput(w *os.File) bool {
	if w == nil {
		return false
	}
	info, err := w.Stat()
	if err != nil {
		return false
	}
	// Homebrew service 会把 stdout/stderr 写入日志文件；非交互式输出不打印连接二维码和 Token，
	// 避免外侧 agentd 访问凭证长期留在服务日志里。`agentd start` 仍会在当前终端显式打印二维码。
	return info.Mode()&os.ModeCharDevice != 0
}

func printConnectionQRCode(w io.Writer, connectURL string) {
	if strings.TrimSpace(connectURL) == "" {
		return
	}
	// 二维码只承载短期配对票据，不包含长期 agentd token 或本机 app-server upstream token。
	code, err := qrcode.New(connectURL, qrcode.Medium)
	if err != nil {
		fmt.Fprintf(w, "二维码生成失败：%v\n", err)
		return
	}
	fmt.Fprintln(w)
	fmt.Fprint(w, code.ToSmallString(false))
}

func printWarnings(w io.Writer, warnings []string) {
	for _, warning := range warnings {
		fmt.Fprintf(w, "警告：%s\n", warning)
	}
}

func waitForServiceHealth(ctx context.Context, endpoint string, timeout time.Duration) error {
	if timeout <= 0 {
		return nil
	}
	healthURL, err := healthCheckURL(endpoint)
	if err != nil {
		return err
	}
	deadline := time.Now().Add(timeout)
	client := http.Client{Timeout: time.Second}
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, healthURL, nil)
		if err != nil {
			return err
		}
		resp, err := client.Do(req)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				return nil
			}
			err = fmt.Errorf("healthz HTTP %d", resp.StatusCode)
		}
		if time.Now().After(deadline) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(300 * time.Millisecond):
		}
	}
}

func healthCheckURL(endpoint string) (string, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", fmt.Errorf("Endpoint 无效：%s", endpoint)
	}
	parsed.Path = "/healthz"
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}
