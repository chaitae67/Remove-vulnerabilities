package com.example.clinic.controller;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Enumeration;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class VulnerableNetworkController {

    private final HttpClient httpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(3))
        .followRedirects(HttpClient.Redirect.ALWAYS)
        .build();

    @GetMapping("/tools/url-preview")
    public ResponseEntity<String> previewUrl(@RequestParam String url) throws IOException, InterruptedException {
        /*
         * VULNERABLE LAB - SF:
         * 사용자가 입력한 URL을 allowlist, 사설망 차단, 스키마 제한 없이 서버가 직접 요청한다.
         * 따라서 내부 관리자 콘솔, 메타데이터 주소, 로컬 서비스 등에 대한 SSRF 점검이 가능하다.
         */
        HttpRequest request = HttpRequest.newBuilder(URI.create(url))
            .timeout(Duration.ofSeconds(5))
            .GET()
            .build();
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        String body = response.body() == null ? "" : response.body();
        String preview = body.length() > 2000 ? body.substring(0, 2000) : body;
        return ResponseEntity.ok()
            .contentType(MediaType.TEXT_PLAIN)
            .body("status=" + response.statusCode() + "\n" + preview);
    }

    @RequestMapping(
        value = "/debug/request-echo",
        method = {RequestMethod.TRACE, RequestMethod.OPTIONS, RequestMethod.PUT, RequestMethod.DELETE, RequestMethod.PATCH}
    )
    public ResponseEntity<String> echoRequest(HttpServletRequest request) {
        /*
         * VULNERABLE LAB - WM:
         * 운영에 필요하지 않은 HTTP 메서드를 디버그 목적으로 열어두고 요청 정보를 반사한다.
         */
        StringBuilder response = new StringBuilder();
        response.append(request.getMethod()).append(' ').append(request.getRequestURI()).append('\n');
        Enumeration<String> names = request.getHeaderNames();
        while (names.hasMoreElements()) {
            String name = names.nextElement();
            response.append(name).append(": ").append(request.getHeader(name)).append('\n');
        }
        return ResponseEntity.ok()
            .contentType(MediaType.TEXT_PLAIN)
            .body(response.toString());
    }
}
