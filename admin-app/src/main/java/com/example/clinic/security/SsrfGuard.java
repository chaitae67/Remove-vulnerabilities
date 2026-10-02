package com.example.clinic.security;

import java.net.InetAddress;
import java.net.URI;
import java.net.UnknownHostException;

/**
 * SF-08: 서버 사이드 요청 위조(SSRF) 방지 유틸리티.
 * 외부에서 입력받은 URL이 http/https 인지, 그리고 목적지 호스트가 내부망/사설/루프백
 * 주소가 아닌지 검증한다. 검증에 실패하면 예외를 던진다.
 */
public final class SsrfGuard {

    private SsrfGuard() {
    }

    public static URI validate(String rawUrl) {
        if (rawUrl == null || rawUrl.isBlank()) {
            throw new IllegalArgumentException("URL이 비어 있습니다.");
        }
        URI uri;
        try {
            uri = URI.create(rawUrl.trim());
        } catch (IllegalArgumentException ex) {
            throw new IllegalArgumentException("올바르지 않은 URL 형식입니다.");
        }
        String scheme = uri.getScheme();
        if (scheme == null || !(scheme.equalsIgnoreCase("http") || scheme.equalsIgnoreCase("https"))) {
            throw new IllegalArgumentException("http 또는 https URL만 허용됩니다.");
        }
        String host = uri.getHost();
        if (host == null || host.isBlank()) {
            throw new IllegalArgumentException("호스트를 확인할 수 없습니다.");
        }
        try {
            for (InetAddress address : InetAddress.getAllByName(host)) {
                if (isBlocked(address)) {
                    throw new IllegalArgumentException("내부망 또는 사설 IP로의 요청은 허용되지 않습니다.");
                }
            }
        } catch (UnknownHostException ex) {
            throw new IllegalArgumentException("호스트를 확인할 수 없습니다.");
        }
        return uri;
    }

    private static boolean isBlocked(InetAddress address) {
        return address.isAnyLocalAddress()
            || address.isLoopbackAddress()
            || address.isLinkLocalAddress()
            || address.isSiteLocalAddress()   // 10.x, 172.16-31.x, 192.168.x
            || address.isMulticastAddress()
            || isUniqueLocalIpv6(address);
    }

    private static boolean isUniqueLocalIpv6(InetAddress address) {
        byte[] bytes = address.getAddress();
        // IPv6 ULA(fc00::/7) 및 IPv4 100.64.0.0/10(CGNAT) 차단
        if (bytes.length == 16) {
            return (bytes[0] & 0xfe) == 0xfc;
        }
        if (bytes.length == 4) {
            int first = bytes[0] & 0xff;
            int second = bytes[1] & 0xff;
            return first == 100 && second >= 64 && second <= 127;
        }
        return false;
    }
}
