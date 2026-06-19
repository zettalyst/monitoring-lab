package com.example.setlog.api;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import static com.example.setlog.api.SetLogDtos.ClipRequest;
import static com.example.setlog.api.SetLogDtos.ClipResponse;
import static com.example.setlog.api.SetLogDtos.FeedResponse;
import static com.example.setlog.api.SetLogDtos.RenderJobRequest;
import static com.example.setlog.api.SetLogDtos.RenderJobResponse;
import static com.example.setlog.api.SetLogDtos.RoomResponse;

@RestController
@RequestMapping("/api")
class SetLogController {

    private final SetLogService service;

    SetLogController(SetLogService service) {
        this.service = service;
    }

    @PostMapping("/rooms")
    RoomResponse createRoom() {
        return service.createRoom();
    }

    @PostMapping("/clips")
    ClipResponse uploadClip(@RequestBody ClipRequest request) {
        return service.uploadClip(request);
    }

    @PostMapping("/render-jobs")
    RenderJobResponse renderDailyVlog(@RequestBody RenderJobRequest request) {
        return service.renderDailyVlog(request);
    }

    @GetMapping("/feed")
    FeedResponse readFeed() {
        return service.readFeed();
    }
}
