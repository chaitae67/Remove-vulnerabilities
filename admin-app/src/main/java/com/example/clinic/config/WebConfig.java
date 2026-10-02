package com.example.clinic.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * WEB-17/WEB-24: 업로드 디렉터리를 웹 경로(/uploads/**)로 직접 노출하던 가상 디렉터리 매핑을 제거했다.
 * 관리자 화면에서는 이 경로를 참조하지 않으며, 첨부/의무기록 파일은 접근 통제와
 * Content-Disposition(첨부)이 적용된 전용 컨트롤러로만 제공한다.
 */
@Configuration
public class WebConfig implements WebMvcConfigurer {
}
