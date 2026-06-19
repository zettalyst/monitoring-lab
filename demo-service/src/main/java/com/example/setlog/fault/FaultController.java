package com.example.setlog.fault;

import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import static com.example.setlog.fault.FaultDtos.CpuFaultRequest;
import static com.example.setlog.fault.FaultDtos.DbPoolFaultRequest;
import static com.example.setlog.fault.FaultDtos.DiskFaultRequest;
import static com.example.setlog.fault.FaultDtos.ErrorFaultRequest;
import static com.example.setlog.fault.FaultDtos.FaultStatus;
import static com.example.setlog.fault.FaultDtos.LatencyFaultRequest;
import static com.example.setlog.fault.FaultDtos.RenderFaultRequest;

@RestController
@RequestMapping("/internal/faults")
class FaultController {

    private final FaultState faultState;

    FaultController(FaultState faultState) {
        this.faultState = faultState;
    }

    @GetMapping
    FaultStatus status() {
        return faultState.status();
    }

    @PostMapping("/latency")
    FaultStatus latency(@RequestBody LatencyFaultRequest request) {
        return faultState.configureLatency(request.latencyMs());
    }

    @PostMapping("/errors")
    FaultStatus errors(@RequestBody ErrorFaultRequest request) {
        return faultState.configureErrors(request.errorRatePercent());
    }

    @PostMapping("/cpu")
    FaultStatus cpu(@RequestBody CpuFaultRequest request) {
        return faultState.configureCpu(request.enabled(), request.workers());
    }

    @PostMapping("/disk")
    FaultStatus disk(@RequestBody DiskFaultRequest request) {
        return faultState.configureDisk(request.enabled(), request.megabytes());
    }

    @PostMapping("/db-pool")
    FaultStatus dbPool(@RequestBody DbPoolFaultRequest request) {
        return faultState.configureDbPool(request.enabled(), request.holders(), request.holdMillis());
    }

    @PostMapping("/render")
    FaultStatus render(@RequestBody RenderFaultRequest request) {
        return faultState.configureRender(request.enabled(), request.delayMs());
    }

    @DeleteMapping
    FaultStatus reset() {
        return faultState.reset();
    }
}
