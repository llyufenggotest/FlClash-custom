//go:build !(ios && !with_low_memory)

package main

// Non-iOS-app builds keep upstream behaviour: this process owns the profile's
// DNS listener and the canonical bbolt cache file.
const disableDNSListener = false

const dnsListenerOwner = "self"

const secondaryCacheFileName = ""
