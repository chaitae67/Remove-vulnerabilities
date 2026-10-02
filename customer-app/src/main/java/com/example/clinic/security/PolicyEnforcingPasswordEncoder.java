package com.example.clinic.security;

import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

/**
 * 기존 DB에 약한 BCrypt 해시가 남아 있어도 약한 원문 비밀번호로는 인증하지 않는다.
 * 고객은 비밀번호 찾기 절차로 정책을 만족하는 비밀번호를 설정해야 한다.
 */
public final class PolicyEnforcingPasswordEncoder implements PasswordEncoder {

    private final PasswordEncoder delegate = new BCryptPasswordEncoder();

    @Override
    public String encode(CharSequence rawPassword) {
        // Spring Security가 사용자 미존재 시 시간차 공격 방지용 더미 값을 인코딩하므로
        // 정책 검사는 UserService/DataSeeder와 matches()에서 수행한다.
        return delegate.encode(rawPassword);
    }

    @Override
    public boolean matches(CharSequence rawPassword, String encodedPassword) {
        return PasswordPolicy.isStrong(rawPassword) && delegate.matches(rawPassword, encodedPassword);
    }

    @Override
    public boolean upgradeEncoding(String encodedPassword) {
        return delegate.upgradeEncoding(encodedPassword);
    }
}
