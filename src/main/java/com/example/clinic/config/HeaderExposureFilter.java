package com.example.clinic.config;

import java.io.IOException;

import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@Component
public class HeaderExposureFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        // VULNERABLE LAB - WEB-16: 응답 헤더에 WAS/서블릿 버전 정보를 노출한다.
        response.setHeader("X-Powered-By", "Servlet/6.0; JSP/3.1");
        filterChain.doFilter(request, response);
    }
}
