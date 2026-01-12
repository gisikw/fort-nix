(function() {
  var FONT = "'ProggyClean Nerd Font', monospace";

  function getFiberKey(el) {
    return Object.keys(el).find(function(k) {
      return k.startsWith('__reactFiber$');
    });
  }

  function findInHooks(fiber, predicate) {
    if (!fiber || !fiber.memoizedState) return null;
    var state = fiber.memoizedState;
    while (state) {
      var val = state.memoizedState;
      var found = predicate(val);
      if (found) return found;
      state = state.next;
    }
    return null;
  }

  function findTerminalRefs(xtermEl) {
    var parent = xtermEl.parentElement;
    if (!parent) return null;

    var fiberKey = getFiberKey(parent);
    if (!fiberKey) return null;

    var fiber = parent[fiberKey];
    var result = { terminal: null, fitAddon: null, webSocket: null };

    var depth = 0;
    while (fiber && depth < 20) {
      if (!result.terminal) {
        result.terminal = findInHooks(fiber, function(val) {
          return (val && val._core && val.options) ? val : null;
        });
      }
      if (!result.fitAddon) {
        result.fitAddon = findInHooks(fiber, function(val) {
          if (val && typeof val.fit === 'function' && typeof val.proposeDimensions === 'function') return val;
          if (val && val.current && typeof val.current.fit === 'function') return val.current;
          return null;
        });
      }
      if (!result.webSocket) {
        result.webSocket = findInHooks(fiber, function(val) {
          return (val && val.current && typeof val.current.send === 'function' && 'readyState' in val.current)
            ? val.current : null;
        });
      }
      if (result.terminal && result.fitAddon && result.webSocket) break;
      fiber = fiber.return;
      depth++;
    }

    return result.terminal ? result : null;
  }

  function patchTerminal(el) {
    if (el.__fortPatched) return;

    var refs = findTerminalRefs(el);
    if (!refs || !refs.terminal) return;

    el.__fortPatched = true;
    refs.terminal.options.fontFamily = FONT;

    // Wait for font to load, then refit
    setTimeout(function() {
      // Remeasure character cell dimensions
      var charSizeService = refs.terminal._core._charSizeService;
      if (charSizeService && charSizeService.measure) {
        charSizeService.measure();
      }

      // Refit terminal to container
      if (refs.fitAddon && refs.fitAddon.fit) {
        refs.fitAddon.fit();
      }

      // Notify backend of new size
      if (refs.webSocket && refs.webSocket.readyState === WebSocket.OPEN) {
        refs.webSocket.send(JSON.stringify({
          type: 'resize',
          data: { cols: refs.terminal.cols, rows: refs.terminal.rows }
        }));
      }
    }, 50);
  }

  function tryPatch() {
    document.querySelectorAll('.xterm').forEach(patchTerminal);
  }

  setInterval(tryPatch, 500);
})();
