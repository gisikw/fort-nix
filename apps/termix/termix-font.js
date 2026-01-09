(function() {
  var FONT = "'ProggyClean Nerd Font', monospace";

  // Expose for debugging
  window.__fort = {
    FONT: FONT,
    terminals: [],
    elements: [],
    lastError: null,

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

    // Inspect an element for terminal instance
    inspect: function(el) {
      var results = { keys: [], terminalFound: null };
      var node = el || document.querySelector('.xterm');
      while (node) {
        var keys = Object.keys(node);
        results.keys.push({ element: node.tagName + '.' + node.className, props: keys });
        for (var i = 0; i < keys.length; i++) {
          try {
            var val = node[keys[i]];
            if (val && val.options && val._core) {
              results.terminalFound = { key: keys[i], terminal: val };
              return results;
            }
          } catch (e) {}
        }
        node = node.parentElement;
      }
      return results;
    },

    tryPatch: function() {
      document.querySelectorAll('.xterm').forEach(function(el) {
        window.__fort.elements.push(el);
        if (el.__fortPatched) return;

        // Walk up DOM tree looking for terminal instance
        var node = el;
        while (node) {
          var keys = Object.keys(node);
          for (var i = 0; i < keys.length; i++) {
            try {
              var val = node[keys[i]];
              // xterm Terminal instances have .options and ._core
              if (val && val.options && val._core) {
                el.__fortPatched = true;
                window.__fort.terminals.push(val);
                val.options.fontFamily = FONT;
                console.log('[fort] Set terminal fontFamily');
                return;
              }
            } catch (e) {
              window.__fort.lastError = e;
            }
          }
          node = node.parentElement;
        }
        console.log('[fort] Could not find terminal instance for element');
      });
    }
  };

  // Poll for terminals
  setInterval(window.__fort.tryPatch, 500);

  console.log('[fort] Font patcher initialized. Debug: window.__fort');
})();
