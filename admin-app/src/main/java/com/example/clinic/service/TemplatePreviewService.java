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
public class TemplatePreviewService {

    private final Configuration configuration;

    public TemplatePreviewService() {
        Configuration cfg = new Configuration(Configuration.VERSION_2_3_32);
        cfg.setDefaultEncoding("UTF-8");
        cfg.setLocale(Locale.KOREA);
        cfg.setTemplateExceptionHandler(TemplateExceptionHandler.RETHROW_HANDLER);
        this.configuration = cfg;
    }

    public String render(String userTemplate, Map<String, Object> variables) throws Exception {
        Template template = new Template("preview", new StringReader(userTemplate), configuration);
        StringWriter writer = new StringWriter();
        template.process(variables, writer);
        return writer.toString();
    }
}
