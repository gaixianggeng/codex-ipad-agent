//go:build windows

package setup

// Windows Defender Firewall rules require an explicit user decision and elevation.
// A fresh Windows configuration therefore remains loopback-only until the installer
// has successfully created the Private/LocalSubnet rule.
const automaticLANFallbackEnabled = false
