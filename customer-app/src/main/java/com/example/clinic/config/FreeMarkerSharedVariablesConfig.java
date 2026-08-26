package com.example.clinic.config;

import org.springframework.stereotype.Component;
import org.springframework.web.servlet.view.freemarker.FreeMarkerConfigurer;

import com.example.clinic.config.freemarker.TemplateNumbers;
import com.example.clinic.config.freemarker.TemplateStrings;
import com.example.clinic.config.freemarker.TemplateTemporals;

/**
 * Thymeleaf의 #numbers / #temporals 유틸리티 객체를 대체하기 위해
 * FreeMarker Configuration에 동일한 이름의 공유 변수를 등록한다.
 */
@Component
public class FreeMarkerSharedVariablesConfig {

    public FreeMarkerSharedVariablesConfig(FreeMarkerConfigurer configurer) throws Exception {
        configurer.getConfiguration().setSharedVariable("numbers", new TemplateNumbers());
        configurer.getConfiguration().setSharedVariable("temporals", new TemplateTemporals());
        configurer.getConfiguration().setSharedVariable("strings", new TemplateStrings());
    }
}
