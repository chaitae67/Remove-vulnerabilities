package com.example.clinic.config;

import freemarker.core.HTMLOutputFormat;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.view.freemarker.FreeMarkerConfigurer;

/**
 * XS-06: FreeMarker의 출력 형식을 HTML로 지정하여 모든 ${...} 보간에
 * HTML 자동 이스케이프가 적용되도록 한다(저장형/반사형 XSS 차단).
 *
 * FreeMarkerConfigurer를 생성자 주입 받으므로, 주입 시점에는 내부 Configuration이
 * 이미 초기화되어 있어 안전하게 출력 형식을 설정할 수 있다.
 */
@Configuration
public class FreeMarkerSecurityConfig {

    public FreeMarkerSecurityConfig(FreeMarkerConfigurer freeMarkerConfigurer) {
        freeMarkerConfigurer.getConfiguration().setOutputFormat(HTMLOutputFormat.INSTANCE);
    }
}
