### Summary

<!-- What does this PR change and why? -->

### Changes

-
-

### Testing

- [ ] `xcodegen generate && xcodebuild -scheme SimulatorCamera build` succeeds
- [ ] Extension activates (`systemextensionsctl list` shows it enabled)
- [ ] `simcamctl ping` / `simcamctl status` report a running stream
- [ ] Verified frames reach an app on an Xcode 16+ iOS Simulator

### XPC contract impact

- [ ] No change to `Shared/XPCContract.swift`
- [ ] Changed — app, extension, and `simcamctl` all updated together

### Checklist

- [ ] Added/updated entry in `CHANGELOG.md` under `[Unreleased]`
- [ ] No private APIs introduced
- [ ] Consuming iOS apps still need zero imports and zero project changes
