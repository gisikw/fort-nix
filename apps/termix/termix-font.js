(function() {
  var FONT = "'ProggyClean Nerd Font', monospace";

  // Find React fiber key on an element
  function getFiberKey(el) {
    return Object.keys(el).find(function(k) {
      return k.startsWith('__reactFiber$');
    });
  }

  // Search fiber tree for terminal instance
  function findTerminalInFiber(fiber, depth) {
    if (!fiber || depth > 50) return null;

    // Check memoizedState chain
    var state = fiber.memoizedState;
    while (state) {
      // Terminal might be in state directly
      if (state.memoizedState && state.memoizedState.options && state.memoizedState._core) {
        return state.memoizedState;
      }
      // Or in a ref
      if (state.memoizedState && state.memoizedState.current) {
        var ref = state.memoizedState.current;
        if (ref && ref.options && ref._core) {
          return ref;
        }
      }
      state = state.next;
    }

    // Check stateNode
    if (fiber.stateNode && fiber.stateNode.options && fiber.stateNode._core) {
      return fiber.stateNode;
    }

    // Recurse into child
    var childResult = findTerminalInFiber(fiber.child, depth + 1);
    if (childResult) return childResult;

    // Recurse into sibling
    return findTerminalInFiber(fiber.sibling, depth + 1);
  }

  // Expose for debugging
  window.__fort = {
    FONT: FONT,
    terminals: [],
    elements: [],
    lastError: null,
    lastFiber: null,

    // Manual trigger to try patching again
    patch: function() {
      window.__fort.tryPatch();
    },

    // Set font on a terminal instance directly
    setFont: function(terminal) {
      if (terminal && terminal.options) {
        terminal.options.fontFamily = FONT;
        console.log('[fort] Set fontFamily on terminal');
        return true;
      }
      return false;
    },

    // Get fiber from element
    getFiber: function(el) {
      var key = getFiberKey(el);
      return key ? el[key] : null;
    },

    // Inspect fiber tree for terminal
    inspectFiber: function(el) {
      el = el || document.querySelector('.xterm');
      // Walk up to find element with fiber
      while (el && !getFiberKey(el)) {
        el = el.parentElement;
      }
      if (!el) return { error: 'No fiber found' };

      var fiber = el[getFiberKey(el)];
      window.__fort.lastFiber = fiber;
      return findTerminalInFiber(fiber, 0);
    },

    tryPatch: function() {
      document.querySelectorAll('.xterm').forEach(function(el) {
        if (el.__fortPatched) return;
        window.__fort.elements.push(el);

        // Walk up to find element with React fiber
        var node = el;
        while (node && !getFiberKey(node)) {
          node = node.parentElement;
        }

        if (!node) {
          console.log('[fort] No React fiber found');
          return;
        }

        try {
          var fiber = node[getFiberKey(node)];
          var terminal = findTerminalInFiber(fiber, 0);

          if (terminal) {
            el.__fortPatched = true;
            window.__fort.terminals.push(terminal);
            terminal.options.fontFamily = FONT;
            console.log('[fort] Set terminal fontFamily via fiber');
            return;
          }
        } catch (e) {
          window.__fort.lastError = e;
        }

        console.log('[fort] Could not find terminal in fiber tree');
      });
    }
  };

  // Poll for terminals
  setInterval(window.__fort.tryPatch, 500);

  console.log('[fort] Font patcher initialized. Debug: window.__fort');
})();
