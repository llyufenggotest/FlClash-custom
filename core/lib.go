//go:build cgo

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"core/platform"
	t "core/tun"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"syscall"
	"unsafe"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"golang.org/x/sync/semaphore"
)

var (
	eventListenerMu sync.RWMutex
	eventListener   unsafe.Pointer
)

type TunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer

	limit *semaphore.Weighted
}

// start brings up the TUN listener and reports whether a data path actually
// exists afterwards.
//
// The boolean is not cosmetic: on iOS the caller uses it to decide whether to
// roll back a partial start. A 2026-08-29 device trace caught
// `syscall.Dup` failing with "bad file descriptor", so `t.Start` returned nil,
// yet the old code reported success all the way up to Swift. The tunnel then sat
// in "connected" with no data path at all, which the user experiences as a
// profile that connects but carries no traffic.
func (th *TunHandler) start(fd int, options t.Options) bool {
	runLock.Lock()
	defer runLock.Unlock()
	_ = th.limit.Acquire(context.TODO(), 4)
	defer th.limit.Release(4)
	th.initHook()
	tunListener := t.Start(fd, options)
	if tunListener != nil {
		log.Infoln("TUN address: %v", tunListener.Address())
		th.listener = tunListener
		return true
	}
	th.clear()
	return false
}

func (th *TunHandler) close() {
	_ = th.limit.Acquire(context.TODO(), 4)
	defer th.limit.Release(4)
	th.clear()
}

func (th *TunHandler) clear() {
	th.removeHook()
	if th.listener != nil {
		_ = th.listener.Close()
	}
	if th.callback != nil {
		releaseObject(th.callback)
	}
	th.callback = nil
	th.listener = nil
}

func (th *TunHandler) handleProtect(fd int) {
	_ = th.limit.Acquire(context.Background(), 1)
	defer th.limit.Release(1)

	if th.listener == nil {
		return
	}

	protect(th.callback, fd)
}

func (th *TunHandler) handleResolveProcess(source, target net.Addr) string {
	_ = th.limit.Acquire(context.Background(), 1)
	defer th.limit.Release(1)

	if th.listener == nil || th.callback == nil {
		return ""
	}
	var protocol int
	uid := -1
	switch source.Network() {
	case "udp", "udp4", "udp6":
		protocol = syscall.IPPROTO_UDP
	case "tcp", "tcp4", "tcp6":
		protocol = syscall.IPPROTO_TCP
	}
	if version < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	}
	return resolveProcess(th.callback, protocol, source.String(), target.String(), uid)
}

func (th *TunHandler) initHook() {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		return conn.Control(func(fd uintptr) {
			tunHandler.handleProtect(int(fd))
		})
	}
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
		if src == nil || dst == nil {
			return "", process.ErrInvalidNetwork
		}
		return tunHandler.handleResolveProcess(src, dst), nil
	}
}

func (th *TunHandler) removeHook() {
	dialer.DefaultSocketHook = nil
	process.DefaultPackageNameResolver = nil
}

var (
	tunLock    sync.Mutex
	errBlocked = errors.New("blocked")
	tunHandler *TunHandler
)

func handleStopTun() {
	tunLock.Lock()
	defer tunLock.Unlock()
	if tunHandler != nil {
		tunHandler.close()
	}
}

// handleStartTun reports whether the TUN data path is live. A false result means
// the caller must not treat the tunnel as usable.
func handleStartTun(callback unsafe.Pointer, fd int, options t.Options) bool {
	handleStopTun()
	tunLock.Lock()
	defer tunLock.Unlock()
	if fd == 0 {
		log.Errorln("TUN: refusing to start with fd=0")
		return false
	}
	tunHandler = &TunHandler{
		callback: callback,
		limit:    semaphore.NewWeighted(4),
	}
	return tunHandler.start(fd, options)
}

func (response MethodResponse) send() {
	if response.callback != nil {
		defer releaseObject(response.callback)
	}
	data, err := response.JSON()
	if err != nil {
		logError("MethodResponse marshal error: id=%s err=%v", response.ID, err)
		data, err = (&MethodResponse{
			ID: response.ID,
			Error: &MethodError{
				Code:    "serialization_error",
				Message: "failed to serialize method response",
				Details: err.Error(),
			},
		}).JSON()
		if err != nil {
			logError("Fallback MethodResponse marshal error: id=%s err=%v", response.ID, err)
			return
		}
	}
	invokeResult(response.callback, string(data))
}

func handlePlatformMethodCall(call *MethodCall, response MethodResponse) bool {
	switch call.Method {
	case updateDnsMethod:
		value := ""
		if !decodeMethodArguments(call, response, &value) {
			return true
		}
		handleUpdateDns(value)
		response.success(true)
		return true
	}
	return false
}

//export invokeMethod
func invokeMethod(callback unsafe.Pointer, paramsChar *C.char) {
	params := takeCString(paramsChar)
	call := &MethodCall{}
	err := json.Unmarshal([]byte(params), call)
	if err != nil {
		response := MethodResponse{callback: callback}
		response.failure("invalid_method_call", err.Error(), nil)
		return
	}
	response := MethodResponse{
		ID:       call.ID,
		callback: callback,
	}
	go handleMethodCall(call, response)
}

//export startTUN
func startTUN(callback unsafe.Pointer, fd C.int, optionsChar *C.char) bool {
	options := t.Options{}
	if err := json.Unmarshal([]byte(takeCString(optionsChar)), &options); err != nil {
		log.Errorln("TUN options:", err)
		if callback != nil {
			releaseObject(callback)
		}
		return false
	}
	started := handleStartTun(callback, int(fd), options)
	// The listener/connection steps run exactly as before even on failure: they
	// own the mixed-port inbound the iOS proxy settings and checkIp depend on,
	// and the caller rolls the whole start back when `started` is false.
	if !isRunning {
		handleStartListener()
	} else {
		handleResetConnections()
	}
	if !started {
		log.Errorln("TUN: data path unavailable; reporting start failure")
	}
	return started
}

//export quickSetup
func quickSetup(callback unsafe.Pointer, initParamsChar *C.char, setupParamsChar *C.char) {
	go func() {
		defer releaseObject(callback)
		initParamsString := takeCString(initParamsChar)
		setupParamsString := takeCString(setupParamsChar)
		initParams := InitParams{}
		if err := json.Unmarshal([]byte(initParamsString), &initParams); err != nil || !handleInitClash(&initParams) {
			invokeResult(callback, "init failed")
			return
		}
		isRunning = true
		setupParams := defaultSetupParams()
		if err := UnmarshalJson([]byte(setupParamsString), setupParams); err != nil {
			invokeResult(callback, err.Error())
			return
		}
		message := handleSetupConfig(setupParams)
		invokeResult(callback, message)
	}()
}

//export setEventListener
func setEventListener(listener unsafe.Pointer) {
	eventListenerMu.Lock()
	defer eventListenerMu.Unlock()
	if eventListener != nil {
		releaseObject(eventListener)
	}
	eventListener = listener
}

//export getTotalTraffic
func getTotalTraffic(onlyStatisticsProxy bool) *C.char {
	return C.CString(marshalResult(handleGetTotalTraffic(onlyStatisticsProxy)))
}

//export getTraffic
func getTraffic(onlyStatisticsProxy bool) *C.char {
	return C.CString(marshalResult(handleGetTraffic(onlyStatisticsProxy)))
}

func marshalResult(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		logError("Result marshal error: %v", err)
		return ""
	}
	return string(data)
}

func sendMessageBatch(messages []Message) {
	arguments, err := json.Marshal(messages)
	if err != nil {
		logError("Message batch marshal error: %v", err)
		return
	}
	call := MethodCall{
		Method:    messageMethod,
		Arguments: arguments,
	}
	data, err := json.Marshal(call)
	if err != nil {
		logError("MethodCall marshal error: method=%s err=%v", call.Method, err)
		return
	}
	eventListenerMu.RLock()
	if eventListener == nil {
		eventListenerMu.RUnlock()
		return
	}
	listener := retainObject(eventListener)
	eventListenerMu.RUnlock()
	defer releaseObject(listener)
	invokeResult(listener, string(data))
}

//export stopTun
func stopTun() {
	handleStopTun()
	if isRunning {
		handleStopListener()
	}
}

//export suspend
func suspend(suspended bool) {
	handleSuspend(suspended)
}

//export forceGC
func forceGC() {
	handleForceGC()
}

//export updateDns
func updateDns(s *C.char) {
	handleUpdateDns(takeCString(s))
}
