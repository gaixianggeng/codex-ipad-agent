(function () {
  function createTerminalLog(options) {
    const term = new Terminal({
      convertEol: true,
      cursorBlink: false,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
      fontSize: 12,
      lineHeight: 1.18,
      scrollback: 5000,
      theme: {
        background: "#0e1117",
        foreground: "#d7dee8",
        cursor: "#ffffff",
        selectionBackground: "#2f4158",
      },
    });

    const fitAddon = new FitAddon.FitAddon();
    let outputQueue = "";
    let outputFlushScheduled = false;
    let flushTimer = null;
    let autoScroll = true;
    let lastSize = null;

    term.loadAddon(fitAddon);
    term.open(options.element);

    function size() {
      return {
        cols: Math.max(40, Math.min(220, term.cols || 100)),
        rows: Math.max(10, Math.min(80, term.rows || 30)),
      };
    }

    function fit() {
      requestAnimationFrame(() => {
        try {
          fitAddon.fit();
          const next = size();
          if (!lastSize || lastSize.cols !== next.cols || lastSize.rows !== next.rows) {
            lastSize = next;
            options.onResize?.(next);
          }
        } catch (_) {}
      });
    }

    function writeAgent(text) {
      term.writeln(`\x1b[90m[agentd]\x1b[0m ${text}`);
    }

    function reset() {
      outputQueue = "";
      outputFlushScheduled = false;
      window.clearTimeout(flushTimer);
      term.reset();
      term.clear();
    }

    function append(text) {
      if (!text) return;
      if (outputQueue.length > 512 * 1024) {
        outputQueue = outputQueue.slice(-256 * 1024);
      }
      outputQueue += text;
      if (outputFlushScheduled) return;
      outputFlushScheduled = true;
      scheduleFlush();
    }

    function scheduleFlush() {
      window.clearTimeout(flushTimer);
      flushTimer = window.setTimeout(flush, 80);
    }

    function flush() {
      const chunkSize = 32 * 1024;
      const chunk = outputQueue.slice(0, chunkSize);
      outputQueue = outputQueue.slice(chunk.length);
      outputFlushScheduled = outputQueue.length > 0;
      if (!chunk) return;

      term.write(chunk, () => {
        if (autoScroll) term.scrollToBottom();
        if (outputFlushScheduled) scheduleFlush();
      });
    }

    function setAutoScroll(value) {
      autoScroll = Boolean(value);
      if (autoScroll) term.scrollToBottom();
    }

    term.onData((data) => {
      options.onData?.(data);
    });

    fit();

    return {
      append,
      fit,
      reset,
      size,
      writeAgent,
      setAutoScroll,
      scrollToBottom: () => term.scrollToBottom(),
    };
  }

  window.createTerminalLog = createTerminalLog;
})();
