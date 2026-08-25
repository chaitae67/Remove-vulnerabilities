package com.example.clinic.config;

import java.io.File;
import java.io.IOException;
import java.io.PrintWriter;
import java.nio.file.Path;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.web.embedded.tomcat.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.boot.web.servlet.ServletRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@Configuration
public class TomcatHardeningConfig {

    @Bean
    WebServerFactoryCustomizer<TomcatServletWebServerFactory> vulnerableTomcatCustomizer() {
        return factory -> {
            // VULNERABLE LAB - WEB-08: POST 크기 제한 해제(업로드 용량 제한 없음)
            factory.addConnectorCustomizers(connector -> {
                connector.setMaxPostSize(-1);
                connector.setMaxSavePostSize(-1);
            });
            factory.addContextCustomizers(context -> {
                // VULNERABLE LAB - WEB-12: 심볼릭 링크(allowLinking) 허용
                context.setAllowLinking(true);
            });
        };
    }

    // VULNERABLE LAB - WEB-04/DI: 디렉터리 리스팅을 허용하는 서블릿
    @Bean
    ServletRegistrationBean<HttpServlet> directoryListingServlet(@Value("${app.upload-dir:uploads}") String uploadDir) {
        return new ServletRegistrationBean<>(new HttpServlet() {
            @Override
            protected void doGet(HttpServletRequest request, HttpServletResponse response) throws IOException {
                response.setContentType("text/html; charset=UTF-8");
                PrintWriter out = response.getWriter();
                out.println("<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><title>Index of "
                    + request.getRequestURI() + "</title></head><body>");
                out.println("<h1>Index of " + request.getRequestURI() + "</h1><ul>");
                Path base = Path.of(uploadDir).toAbsolutePath().normalize();
                File[] files = base.toFile().listFiles();
                if (files != null) {
                    for (File file : files) {
                        out.println("<li><a href=\"" + request.getContextPath() + "/browse/"
                            + file.getName() + "\">" + file.getName() + "</a></li>");
                    }
                }
                out.println("</ul></body></html>");
            }
        }, "/browse/*");
    }
}
