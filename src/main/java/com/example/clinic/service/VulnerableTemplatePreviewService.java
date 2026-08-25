package com.example.clinic.service;

import java.io.IOException;
import java.io.StringReader;
import java.io.StringWriter;
import java.util.Map;

import org.springframework.stereotype.Service;

import freemarker.template.Configuration;
import freemarker.template.Template;
import freemarker.template.TemplateException;

@Service
public class VulnerableTemplatePreviewService {

    private final Configuration configuration;

    public VulnerableTemplatePreviewService(Configuration configuration) {
        this.configuration = configuration;
    }

    public String render(String userTemplate, Map<String, Object> variables) {
        /*
         * VULNERABLE LAB - SSTI:
         * 사용자가 입력한 문자열을 데이터로 취급하지 않고 서버 측 Freemarker 템플릿으로
         * 직접 해석한다. 따라서 입력에 포함된 ${...} 표현식이 서버에서 평가된다.
         * 예) ${7*7} , <#assign ex="freemarker.template.utility.Execute"?new()> ${ex("id")}
         */
        try {
            Template template = new Template("user", new StringReader(userTemplate), configuration);
            StringWriter out = new StringWriter();
            template.process(variables, out);
            return out.toString();
        } catch (IOException | TemplateException ex) {
            throw new IllegalStateException("템플릿 처리 오류", ex);
        }
    }
}
