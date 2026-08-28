//go:build ios && !with_low_memory

package main

// On iOS the app process (Runner) links libclash.a while the Network Extension
// links libclash_lowmem.a. Both processes run ApplyConfig against the same App
// Group home directory, so both would try to bind the profile's DNS listen port
// and open the same bbolt cache. The extension is the process that actually
// owns the TUN and needs fake-ip, so the app process yields both resources.
const disableDNSListener = true

const dnsListenerOwner = "network-extension"

// Distinct cache file: bbolt holds an exclusive lock, so sharing one file makes
// whichever process opens second fail with "can't open cache file: timeout".
const secondaryCacheFileName = "cache-app.db"
