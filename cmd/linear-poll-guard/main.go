package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/linearpollguard"
)

const version = "mim-55-v1"

func main() {
	if err := run(os.Args[1:]); err != nil {
		writeJSON(map[string]any{
			"status": "error",
			"error":  err.Error(),
		})
		os.Exit(2)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("用法：linear-poll-guard begin|phase|status|finish|unlock|version")
	}
	if args[0] == "version" {
		writeJSON(map[string]any{"version": version})
		return nil
	}
	defaultDir, err := linearpollguard.DefaultStateDir()
	if err != nil {
		return err
	}

	switch args[0] {
	case "begin":
		flags := flag.NewFlagSet("begin", flag.ContinueOnError)
		stateDir := flags.String("state-dir", defaultDir, "巡检状态目录")
		runID := flags.String("run-id", "", "当前巡检唯一 ID")
		startedAtText := flags.String("started-at", "", "RFC3339 开始时间；默认当前时间")
		hardLimit := flags.Duration("hard-limit", linearpollguard.DefaultHardLimit, "硬上限，仅用于诊断")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		startedAt, err := parseOptionalTime(*startedAtText)
		if err != nil {
			return err
		}
		snapshot, err := linearpollguard.NewStore(*stateDir).Begin(*runID, startedAt, *hardLimit)
		if errors.Is(err, linearpollguard.ErrRunActive) {
			// 已有租约是正常的 fail-closed 结果；保持 0 退出码，避免 Agent 把它误当成可重试故障。
			writeJSON(snapshot)
			return nil
		}
		if err != nil {
			return err
		}
		writeJSON(snapshot)
		return nil

	case "phase":
		flags := flag.NewFlagSet("phase", flag.ContinueOnError)
		stateDir := flags.String("state-dir", defaultDir, "巡检状态目录")
		runID := flags.String("run-id", "", "当前巡检唯一 ID")
		phase := flags.String("phase", "", "当前阶段")
		tool := flags.String("tool", "", "即将调用的外部工具")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		snapshot, err := linearpollguard.NewStore(*stateDir).Phase(*runID, *phase, *tool)
		if err != nil {
			return err
		}
		writeJSON(snapshot)
		return nil

	case "status":
		flags := flag.NewFlagSet("status", flag.ContinueOnError)
		stateDir := flags.String("state-dir", defaultDir, "巡检状态目录")
		hardLimit := flags.Duration("hard-limit", linearpollguard.DefaultHardLimit, "硬上限，仅用于诊断")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		writeJSON(linearpollguard.NewStore(*stateDir).Inspect(*hardLimit))
		return nil

	case "finish":
		flags := flag.NewFlagSet("finish", flag.ContinueOnError)
		stateDir := flags.String("state-dir", defaultDir, "巡检状态目录")
		runID := flags.String("run-id", "", "当前巡检唯一 ID")
		conclusion := flags.String("conclusion", "", "本轮结论")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		snapshot, err := linearpollguard.NewStore(*stateDir).Finish(*runID, *conclusion)
		if err != nil {
			return err
		}
		writeJSON(snapshot)
		return nil

	case "unlock":
		flags := flag.NewFlagSet("unlock", flag.ContinueOnError)
		stateDir := flags.String("state-dir", defaultDir, "巡检状态目录")
		runID := flags.String("run-id", "", "必须与租约 owner 完全一致")
		reason := flags.String("reason", "", "人工对账后的解锁原因")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		snapshot, err := linearpollguard.NewStore(*stateDir).ManualUnlock(*runID, *reason)
		if err != nil {
			return err
		}
		writeJSON(snapshot)
		return nil

	default:
		return fmt.Errorf("未知命令：%s", strings.TrimSpace(args[0]))
	}
}

func parseOptionalTime(value string) (time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, nil
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("started-at 必须是 RFC3339：%w", err)
	}
	return parsed, nil
}

func writeJSON(value any) {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode(value)
}
