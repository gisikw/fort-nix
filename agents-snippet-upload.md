### File Uploads

Upload files to hosts via the web UI at `https://upload.<domain>/` or directly via the per-host endpoint:

```bash
# Web UI (requires admin group, or VPN)
# https://upload.gisi.network/

# Direct API (VPN-only)
curl -X POST -F "file=@myfile.txt" https://<host>.fort.<domain>/upload
```

Files land in `/var/lib/fort/drops/` on the target host with timestamped filenames.

**Limits:** 500MB max file size.
