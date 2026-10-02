package com.example.clinic.util;

/** IL-05: 목록·공개 화면에 전달하기 전에 개인정보를 서버에서 마스킹한다. */
public final class PrivacyMasker {

    private PrivacyMasker() {
    }

    public static String name(String value) {
        if (value == null || value.isBlank()) {
            return "-";
        }
        int[] points = value.trim().codePoints().toArray();
        if (points.length == 1) {
            return "*";
        }
        if (points.length == 2) {
            return new String(points, 0, 1) + "*";
        }
        return new String(points, 0, 1) + "*".repeat(points.length - 2)
            + new String(points, points.length - 1, 1);
    }

    public static String username(String value) {
        if (value == null || value.isBlank()) {
            return "-";
        }
        String trimmed = value.trim();
        int visible = Math.min(2, trimmed.length());
        return trimmed.substring(0, visible) + "*".repeat(Math.max(3, trimmed.length() - visible));
    }

    public static String email(String value) {
        if (value == null || value.isBlank() || !value.contains("@")) {
            return "-";
        }
        int at = value.indexOf('@');
        String local = value.substring(0, at);
        String domain = value.substring(at + 1);
        String visible = local.isEmpty() ? "" : local.substring(0, 1);
        return visible + "***@" + domain;
    }

    public static String phone(String value) {
        if (value == null || value.isBlank()) {
            return "-";
        }
        String digits = value.replaceAll("\\D", "");
        if (digits.length() < 7) {
            return "*".repeat(digits.length());
        }
        String prefix = digits.substring(0, Math.min(3, digits.length() - 4));
        String suffix = digits.substring(digits.length() - 4);
        return prefix + "-****-" + suffix;
    }
}
