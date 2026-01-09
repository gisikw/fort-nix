(function() {
  var FONT = "'ProggyClean Nerd Font', monospace";

  // Find React fiber key on an element
  function getFiberKey(el) {
    return Object.keys(el).find(function(k) {
      return k.startsWith('__reactFiber$');
    });
  }

  // Walk hooks chain looking for xterm terminal (has _core property)
  function findTerminalInHooks(fiber) {
    if (!fiber || !fiber.memoizedState) return null;

    var state = fiber.memoizedState;
    var hookIndex = 0;

    while (state) {
      // The terminal is stored directly in memoizedState (not in .current like a ref)
      var val = state.memoizedState;
      if (val && val._core && val.options) {
        console.log('[fort] Found terminal at hook index', hookIndex);
        return val;
      }
      state = state.next;
      hookIndex++;
    }
    return null;
  }

  // Walk hooks chain looking for FitAddon (has fit() and proposeDimensions() methods)
  function findFitAddonInHooks(fiber) {
    if (!fiber || !fiber.memoizedState) return null;

    var state = fiber.memoizedState;

    while (state) {
      // Check both ref-style (.current) and direct storage
      var val = state.memoizedState;
      if (val && typeof val.fit === 'function' && typeof val.proposeDimensions === 'function') {
        return val;
      }
      // Also check .current for useRef style
      if (val && val.current && typeof val.current.fit === 'function') {
        return val.current;
      }
      state = state.next;
    }
    return null;
  }

  // Walk hooks chain looking for WebSocket ref
  function findWebSocketInHooks(fiber) {
    if (!fiber || !fiber.memoizedState) return null;

    var state = fiber.memoizedState;

    while (state) {
      var val = state.memoizedState;
      // Check .current for useRef style - WebSocket has readyState and send
      if (val && val.current && typeof val.current.send === 'function' && 'readyState' in val.current) {
        return val.current;
      }
      state = state.next;
    }
    return null;
  }

  // Find terminal, fitAddon, and webSocket starting from .xterm element
  function findTerminal(xtermEl) {
    // Get parent element (xterm creates .xterm inside the ref target)
    var parent = xtermEl.parentElement;
    if (!parent) return null;

    var fiberKey = getFiberKey(parent);
    if (!fiberKey) return null;

    var fiber = parent[fiberKey];
    var result = { terminal: null, fitAddon: null, webSocket: null };

    // Walk up fiber tree looking for component with terminal in hooks
    var depth = 0;
    while (fiber && depth < 20) {
      if (!result.terminal) {
        result.terminal = findTerminalInHooks(fiber);
      }
      if (!result.fitAddon) {
        result.fitAddon = findFitAddonInHooks(fiber);
      }
      if (!result.webSocket) {
        result.webSocket = findWebSocketInHooks(fiber);
      }
      // Found all three, we're done
      if (result.terminal && result.fitAddon && result.webSocket) {
        return result;
      }
      fiber = fiber.return;
      depth++;
    }

    // Return what we found (terminal only for backwards compat)
    return result.terminal ? result : null;
  }

  // Expose for debugging
  window.__fort = {
    FONT: FONT,
    terminals: [],
    fitAddons: [],
    webSockets: [],
    elements: [],
    lastError: null,

    patch: function() {
      window.__fort.tryPatch();
    },

    findTerminal: findTerminal,

    // Full refit sequence: measure char cells, fit to container, notify backend
    refit: function(terminal, fitAddon, webSocket) {
      if (!terminal || !terminal._core) return;

      // 1. Remeasure character cell dimensions with new font
      if (terminal._core._charSizeService && terminal._core._charSizeService.measure) {
        terminal._core._charSizeService.measure();
        console.log('[fort] Remeasured char size');
      }

      // 2. Refit terminal to container with new cell dimensions
      if (fitAddon && fitAddon.fit) {
        fitAddon.fit();
        console.log('[fort] Fitted terminal:', terminal.cols, 'x', terminal.rows);
      }

      // 3. Notify backend of new size
      if (webSocket && webSocket.readyState === WebSocket.OPEN) {
        webSocket.send(JSON.stringify({
          type: 'resize',
          data: { cols: terminal.cols, rows: terminal.rows }
        }));
        console.log('[fort] Sent resize to backend');
      }
    },

    tryPatch: function() {
      document.querySelectorAll('.xterm').forEach(function(el) {
        if (el.__fortPatched) return;

        try {
          var result = findTerminal(el);
          if (result && result.terminal) {
            el.__fortPatched = true;
            window.__fort.terminals.push(result.terminal);
            window.__fort.elements.push(el);
            if (result.fitAddon) {
              window.__fort.fitAddons.push(result.fitAddon);
            }
            if (result.webSocket) {
              window.__fort.webSockets.push(result.webSocket);
            }

            // Set font
            result.terminal.options.fontFamily = FONT;
            console.log('[fort] Set terminal fontFamily');

            // Wait for font to load, then do full refit
            setTimeout(function() {
              window.__fort.refit(result.terminal, result.fitAddon, result.webSocket);
            }, 50);
          }
        } catch (e) {
          window.__fort.lastError = e;
          console.log('[fort] Error:', e);
        }
      });
    }
  };

  // Poll for terminals
  setInterval(window.__fort.tryPatch, 500);

  console.log('[fort] Font patcher initialized. Debug: window.__fort');
})();
