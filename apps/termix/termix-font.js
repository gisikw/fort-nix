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

  // Find terminal starting from .xterm element
  function findTerminal(xtermEl) {
    // Get parent element (xterm creates .xterm inside the ref target)
    var parent = xtermEl.parentElement;
    if (!parent) return null;

    var fiberKey = getFiberKey(parent);
    if (!fiberKey) return null;

    var fiber = parent[fiberKey];

    // Walk up fiber tree looking for component with terminal in hooks
    var depth = 0;
    while (fiber && depth < 20) {
      var terminal = findTerminalInHooks(fiber);
      if (terminal) return terminal;
      fiber = fiber.return;
      depth++;
    }

    return null;
  }

  // Expose for debugging
  window.__fort = {
    FONT: FONT,
    terminals: [],
    elements: [],
    lastError: null,

    patch: function() {
      window.__fort.tryPatch();
    },

    setFont: function(terminal) {
      if (terminal && terminal.options) {
        terminal.options.fontFamily = FONT;
        console.log('[fort] Set fontFamily on terminal');
        return true;
      }
      return false;
    },

    findTerminal: findTerminal,

    tryPatch: function() {
      document.querySelectorAll('.xterm').forEach(function(el) {
        if (el.__fortPatched) return;

        try {
          var terminal = findTerminal(el);
          if (terminal) {
            el.__fortPatched = true;
            window.__fort.terminals.push(terminal);
            terminal.options.fontFamily = FONT;
            console.log('[fort] Set terminal fontFamily');
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
