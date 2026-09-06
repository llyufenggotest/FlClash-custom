//go:build ios && !with_low_memory

package main

// On iOS the app process (Runner) links libclash.a while the Network Extension
// links libclash_lowmem.a. Both processes run ApplyConfig against the same App
// Group home directory, so both would try to bind the profile's DNS listen port
// and open the same bbolt cache. The extension is the process that actually
// owns the TUN and needs fake-ip, so the app process yields both resources.
const disableDNSListener = true

const dnsListenerOwner = "network-extension"

// The iOS app initializer relocates this cache into its validated private
// Application Support/RunnerCore directory; the name alone is not isolation
// from shared-container suspension locks. NE keeps the canonical shared cache.
const secondaryCacheFileName = "cache-app.db"
