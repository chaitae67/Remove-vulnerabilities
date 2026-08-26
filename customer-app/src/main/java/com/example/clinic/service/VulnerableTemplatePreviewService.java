package com.example.clinic.service;

import java.io.StringReader;
import java.io.StringWriter;
import java.util.Locale;
import java.util.Map;

import org.springframework.stereotype.Service;

import freemarker.template.Configuration;
import freemarker.template.Template;
import freemarker.template.TemplateExceptionHandler;

@Service
public class VulnerableTemplatePreviewService {

    private final Configuration configuration;

    public VulnerableTemplatePreviewService() {
        Configuration cfg = new Configuration(Configuration.VERSION_2_3_32);
        cfg.setDefaultEncoding("UTF-8");
        cfg.setLocale(Locale.KOREA);
        cfg.setTemplateExceptionHandler(TemplateExceptionHandler.RETHROW_HANDLER);
        this.configuration = cfg;
    }

    public String render(String userTemplate, Map<String, Object> variables) throws Exception {
        /*
         * VULNERABLE LAB - SSTI:
         * 사용자가 입력한 문자열을 데이터로 취급하지 않고 서버 측 FreeMarker 템플릿으로
         * 직접 컴파일해서 처리한다. 따라서 입력에 포함된 표현식이 서버에서 평가된다.
         */
        Template template = new Template("preview", new StringReader(userTemplate), configuration);
        StringWriter writer = new StringWriter();
        template.process(variables, writer);
        return writer.toString();
    }
}
