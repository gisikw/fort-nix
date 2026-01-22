// Upload Gateway - Web UI for uploading files to fort hosts
//
// Provides a simple file picker + host dropdown, proxies uploads
// to the selected host's /upload endpoint.

package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"strings"
)

var (
	hosts    []string
	domain   string
	bindAddr string
	tmpl     *template.Template
)

func init() {
	// Parse hosts from env (comma-separated)
	hostsEnv := os.Getenv("UPLOAD_HOSTS")
	if hostsEnv == "" {
		hostsEnv = "ratched,q,joker" // fallback
	}
	hosts = strings.Split(hostsEnv, ",")

	domain = os.Getenv("UPLOAD_DOMAIN")
	if domain == "" {
		domain = "gisi.network"
	}

	bindAddr = os.Getenv("UPLOAD_BIND")
	if bindAddr == "" {
		bindAddr = ":8090"
	}

	tmpl = template.Must(template.New("index").Parse(indexHTML))
}

func main() {
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/upload", handleUpload)
	http.HandleFunc("/health", handleHealth)

	log.Printf("Starting upload gateway on %s (hosts: %v)", bindAddr, hosts)
	if err := http.ListenAndServe(bindAddr, nil); err != nil {
		log.Fatal(err)
	}
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	data := struct {
		Hosts []string
	}{
		Hosts: hosts,
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tmpl.Execute(w, data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse the multipart form (max 500MB)
	if err := r.ParseMultipartForm(500 << 20); err != nil {
		jsonError(w, "Failed to parse form: "+err.Error(), http.StatusBadRequest)
		return
	}

	// Get target host
	targetHost := r.FormValue("host")
	if targetHost == "" {
		jsonError(w, "No host selected", http.StatusBadRequest)
		return
	}

	// Validate host is in allowed list
	validHost := false
	for _, h := range hosts {
		if h == targetHost {
			validHost = true
			break
		}
	}
	if !validHost {
		jsonError(w, "Invalid host", http.StatusBadRequest)
		return
	}

	// Get the uploaded file
	file, header, err := r.FormFile("file")
	if err != nil {
		jsonError(w, "No file in request: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer file.Close()

	// Proxy to target host
	targetURL := fmt.Sprintf("https://%s.fort.%s/upload", targetHost, domain)
	log.Printf("Proxying upload to %s (file: %s, size: %d)", targetURL, header.Filename, header.Size)

	resp, err := proxyUpload(targetURL, file, header)
	if err != nil {
		jsonError(w, "Upload failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Forward the response
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func proxyUpload(targetURL string, file multipart.File, header *multipart.FileHeader) (*http.Response, error) {
	// Create a pipe for streaming the multipart form
	pr, pw := io.Pipe()
	writer := multipart.NewWriter(pw)

	go func() {
		defer pw.Close()
		defer writer.Close()

		part, err := writer.CreateFormFile("file", header.Filename)
		if err != nil {
			pw.CloseWithError(err)
			return
		}

		if _, err := io.Copy(part, file); err != nil {
			pw.CloseWithError(err)
			return
		}
	}()

	req, err := http.NewRequest(http.MethodPost, targetURL, pr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())

	return http.DefaultClient.Do(req)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"ok"}`))
}

func jsonError(w http.ResponseWriter, message string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": false,
		"error":   message,
	})
}

const indexHTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Upload - Fort</title>
  <style>
    :root {
      --bg: #1a1a2e;
      --card: #16213e;
      --accent: #0f3460;
      --text: #e4e4e4;
      --text-muted: #888;
      --ok: #4ecca3;
      --err: #e74c3c;
      --border: #2a3f5f;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: system-ui, -apple-system, sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 1rem;
    }
    .card {
      background: var(--card);
      border-radius: 16px;
      padding: 2rem;
      width: 100%;
      max-width: 420px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.3);
    }
    h1 {
      font-size: 1.5rem;
      margin-bottom: 1.5rem;
      text-align: center;
    }
    .form-group {
      margin-bottom: 1.25rem;
    }
    label {
      display: block;
      margin-bottom: 0.5rem;
      color: var(--text-muted);
      font-size: 0.9rem;
    }
    select, input[type="file"] {
      width: 100%;
      padding: 0.75rem 1rem;
      border: 2px solid var(--border);
      border-radius: 8px;
      background: var(--bg);
      color: var(--text);
      font-size: 1rem;
      transition: border-color 0.2s;
    }
    select:focus, input[type="file"]:focus {
      outline: none;
      border-color: var(--ok);
    }
    select {
      cursor: pointer;
      appearance: none;
      background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16' fill='%23888' viewBox='0 0 16 16'%3E%3Cpath d='M8 11L3 6h10l-5 5z'/%3E%3C/svg%3E");
      background-repeat: no-repeat;
      background-position: right 1rem center;
    }
    .file-input-wrapper {
      position: relative;
      border: 2px dashed var(--border);
      border-radius: 8px;
      padding: 2rem 1rem;
      text-align: center;
      cursor: pointer;
      transition: border-color 0.2s, background 0.2s;
    }
    .file-input-wrapper:hover, .file-input-wrapper.dragover {
      border-color: var(--ok);
      background: rgba(78, 204, 163, 0.05);
    }
    .file-input-wrapper input {
      position: absolute;
      inset: 0;
      opacity: 0;
      cursor: pointer;
    }
    .file-input-wrapper .icon {
      font-size: 2rem;
      margin-bottom: 0.5rem;
    }
    .file-input-wrapper .text {
      color: var(--text-muted);
    }
    .file-input-wrapper .filename {
      color: var(--ok);
      font-weight: 500;
      margin-top: 0.5rem;
      word-break: break-all;
    }
    button {
      width: 100%;
      padding: 1rem;
      border: none;
      border-radius: 8px;
      background: var(--ok);
      color: var(--bg);
      font-size: 1rem;
      font-weight: 600;
      cursor: pointer;
      transition: opacity 0.2s, transform 0.1s;
    }
    button:hover:not(:disabled) {
      opacity: 0.9;
    }
    button:active:not(:disabled) {
      transform: scale(0.98);
    }
    button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }
    .result {
      margin-top: 1.5rem;
      padding: 1rem;
      border-radius: 8px;
      font-family: monospace;
      font-size: 0.85rem;
      word-break: break-all;
    }
    .result.success {
      background: rgba(78, 204, 163, 0.1);
      border: 1px solid var(--ok);
      color: var(--ok);
    }
    .result.error {
      background: rgba(231, 76, 60, 0.1);
      border: 1px solid var(--err);
      color: var(--err);
    }
    .progress {
      margin-top: 1rem;
      height: 4px;
      background: var(--border);
      border-radius: 2px;
      overflow: hidden;
    }
    .progress-bar {
      height: 100%;
      background: var(--ok);
      width: 0%;
      transition: width 0.3s;
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>Upload File</h1>
    <form id="uploadForm">
      <div class="form-group">
        <label for="host">Target Host</label>
        <select id="host" name="host" required>
          {{range .Hosts}}
          <option value="{{.}}">{{.}}</option>
          {{end}}
        </select>
      </div>
      <div class="form-group">
        <label>File</label>
        <div class="file-input-wrapper" id="dropZone">
          <input type="file" id="file" name="file" required>
          <div class="icon">+</div>
          <div class="text">Drop file or tap to select</div>
          <div class="filename" id="filename"></div>
        </div>
      </div>
      <button type="submit" id="submitBtn">Upload</button>
      <div class="progress" id="progress" style="display:none">
        <div class="progress-bar" id="progressBar"></div>
      </div>
    </form>
    <div id="result"></div>
  </div>

  <script>
    const form = document.getElementById('uploadForm');
    const fileInput = document.getElementById('file');
    const filename = document.getElementById('filename');
    const dropZone = document.getElementById('dropZone');
    const submitBtn = document.getElementById('submitBtn');
    const progress = document.getElementById('progress');
    const progressBar = document.getElementById('progressBar');
    const result = document.getElementById('result');

    fileInput.addEventListener('change', () => {
      if (fileInput.files.length > 0) {
        filename.textContent = fileInput.files[0].name;
      } else {
        filename.textContent = '';
      }
    });

    ['dragenter', 'dragover'].forEach(e => {
      dropZone.addEventListener(e, (ev) => {
        ev.preventDefault();
        dropZone.classList.add('dragover');
      });
    });

    ['dragleave', 'drop'].forEach(e => {
      dropZone.addEventListener(e, (ev) => {
        ev.preventDefault();
        dropZone.classList.remove('dragover');
      });
    });

    dropZone.addEventListener('drop', (e) => {
      if (e.dataTransfer.files.length > 0) {
        fileInput.files = e.dataTransfer.files;
        filename.textContent = e.dataTransfer.files[0].name;
      }
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();

      if (!fileInput.files.length) {
        showResult('Please select a file', false);
        return;
      }

      submitBtn.disabled = true;
      submitBtn.textContent = 'Uploading...';
      progress.style.display = 'block';
      progressBar.style.width = '0%';
      result.innerHTML = '';

      const formData = new FormData(form);

      try {
        const xhr = new XMLHttpRequest();
        xhr.open('POST', '/upload');

        xhr.upload.addEventListener('progress', (e) => {
          if (e.lengthComputable) {
            const pct = (e.loaded / e.total) * 100;
            progressBar.style.width = pct + '%';
          }
        });

        xhr.onload = () => {
          let data;
          try {
            data = JSON.parse(xhr.responseText);
          } catch {
            data = { error: xhr.responseText };
          }

          if (xhr.status >= 200 && xhr.status < 300 && data.success) {
            showResult('Uploaded: ' + data.path, true);
            fileInput.value = '';
            filename.textContent = '';
          } else {
            showResult(data.error || 'Upload failed', false);
          }

          submitBtn.disabled = false;
          submitBtn.textContent = 'Upload';
          progress.style.display = 'none';
        };

        xhr.onerror = () => {
          showResult('Network error', false);
          submitBtn.disabled = false;
          submitBtn.textContent = 'Upload';
          progress.style.display = 'none';
        };

        xhr.send(formData);
      } catch (err) {
        showResult(err.message, false);
        submitBtn.disabled = false;
        submitBtn.textContent = 'Upload';
        progress.style.display = 'none';
      }
    });

    function showResult(msg, success) {
      result.className = 'result ' + (success ? 'success' : 'error');
      result.textContent = msg;
    }
  </script>
</body>
</html>`
