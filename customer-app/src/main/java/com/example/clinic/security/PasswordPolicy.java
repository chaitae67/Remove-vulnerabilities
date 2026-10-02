package com.example.clinic.security;

import java.util.Locale;
import java.util.Set;

/** BF-09: 신규 비밀번호와 기존 계정 로그인에 동일하게 적용되는 비밀번호 정책. */
public final class PasswordPolicy {

    private static final int MIN_LENGTH = 10;
    private static final int MAX_LENGTH = 128;
    private static final Set<String> BLOCKED = Set.of(
        "password", "password1", "qwerty1234", "admin1234", "user1234", "letmein123"
    );

    private PasswordPolicy() {
    }

    public static boolean isStrong(CharSequence rawPassword) {
        if (rawPassword == null) return false;
        String password = rawPassword.toString();
        if (password.length() < MIN_LENGTH || password.length() > MAX_LENGTH) return false;
        if (BLOCKED.contains(password.toLowerCase(Locale.ROOT))) return false;
        boolean letter = false;
        boolean digit = false;
        boolean special = false;
        for (int i = 0; i < password.length(); i++) {
            char ch = password.charAt(i);
            letter |= Character.isLetter(ch);
            digit |= Character.isDigit(ch);
            special |= !Character.isLetterOrDigit(ch) && !Character.isWhitespace(ch);
        }
        return letter && digit && special;
    }

    public static boolean isStrongForUsername(CharSequence rawPassword, String username) {
        if (!isStrong(rawPassword)) return false;
        if (username == null || username.isBlank()) return true;
        return !rawPassword.toString().toLowerCase(Locale.ROOT)
            .contains(username.trim().toLowerCase(Locale.ROOT));
    }

    public static void requireStrong(CharSequence rawPassword, String username) {
        if (!isStrongForUsername(rawPassword, username)) {
            throw new IllegalArgumentException(
                "비밀번호는 10~128자이며 영문, 숫자, 특수문자를 포함하고 아이디와 달라야 합니다.");
        }
    }
}
