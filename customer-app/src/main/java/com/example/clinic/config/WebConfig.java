package com.example.clinic.config;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * WEB-17/WEB-24: 업로드 디렉터리를 웹 경로(/uploads/**)로 직접 노출하던 가상 디렉터리 매핑을 제거했다.
 * 첨부파일은 접근 통제와 Content-Disposition(첨부)이 적용된 전용 컨트롤러
 * (예: /reviews/{id}/attachments/{id}, /qna/{id}/attachments/{id})로만 제공한다.
 * 이로써 불필요한 가상 디렉터리가 사라지고, 업로드 파일이 웹에서 직접 실행/서빙되지 않는다.
 */
@Configuration
public class WebConfig implements WebMvcConfigurer {
}
