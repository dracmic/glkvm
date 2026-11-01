# GLKVM macOS app: re-enable GPU acceleration

The GLKVM desktop app for macOS (Electron, tested with 1.6.0) disables GPU
acceleration unconditionally (`app.disableHardwareAcceleration()`,
`--disable-gpu`, `--disable-gpu-compositing`). The remote video is then decoded
and composited in software, which costs about one CPU core at 2560x1440;
the same page in Chrome uses roughly a third of that.

`patch_glkvm_app_gpu.sh` neutralises those three statements in `app.asar`
(same-length comments, so no offsets change), updates the asar integrity
hashes in the asar header and in `Info.plist`, re-signs the bundle ad hoc with
its original entitlements, and removes the quarantine attribute.

    ./patch_glkvm_app_gpu.sh status
    ./patch_glkvm_app_gpu.sh apply     # quit GLKVM first
    ./patch_glkvm_app_gpu.sh revert

Environment overrides: `GLKVM_APP` (default `/Applications/GLKVM.app`),
`GLKVM_APP_BACKUP` (default
`~/Library/Application Support/gl-kvm/gpu-patch-backup`).

Notes:

- The first `apply` keeps a pristine copy of `app.asar` and `Info.plist`
  (plus `CodeResources` and the entitlements for reference) in the backup dir.
- After patching, the app is ad-hoc signed instead of GL.iNet's Developer ID.
  `revert` restores the original files but cannot restore that signature;
  reinstall the app from GL.iNet to get the vendor-signed build back.
- The app auto-updates, and an update replaces the patched files. Run `apply`
  again afterwards; it is idempotent and refuses unknown app versions. A backup
  from an older app version is replaced by the new version's pristine files.
