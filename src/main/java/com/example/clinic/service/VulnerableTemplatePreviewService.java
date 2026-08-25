package com.example.clinic.service;

import java.util.Locale;
import java.util.Map;
import org.springframework.stereotype.Service;
import org.thymeleaf.TemplateEngine;
import org.thymeleaf.context.Context;
import org.thymeleaf.spring6.SpringTemplateEngine;
import org.thymeleaf.templatemode.TemplateMode;
import org.thymeleaf.templateresolver.StringTemplateResolver;

@Service
public class VulnerableTemplatePreviewService {

    private final TemplateEngine templateEngine;

    public VulnerableTemplatePreviewService() {
        StringTemplateResolver resolver = new StringTemplateResolver();
        resolver.setTemplateMode(TemplateMode.HTML);
        resolver.setCacheable(false);

        SpringTemplateEngine engine = new SpringTemplateEngine();
        engine.setTemplateResolver(resolver);
        this.templateEngine = engine;
    }

    public String render(String userTemplate, Map<String, Object> variables) {
        Context context = new Context(Locale.KOREA);
        context.setVariables(variables);

        /*
         * VULNERABLE LAB - SSTI:
         * 사용자가 입력한 문자열을 데이터로 취급하지 않고 서버 측 Thymeleaf 템플릿으로
         * 직접 해석한다. 따라서 입력에 포함된 표현식이 서버에서 평가된다.
         */
        return templateEngine.process(userTemplate, context);
    }
}
