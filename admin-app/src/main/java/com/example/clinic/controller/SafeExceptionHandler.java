package com.example.clinic.controller;

import org.springframework.http.HttpStatus;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.MultipartException;
import org.springframework.web.servlet.ModelAndView;

/** 입력 검증 실패를 기본 500 JSON으로 노출하지 않고 최소 정보의 HTML 오류로 변환한다. */
@ControllerAdvice
public class SafeExceptionHandler {

    @ExceptionHandler(AccessDeniedException.class)
    public ModelAndView forbidden() {
        return error(HttpStatus.FORBIDDEN);
    }

    @ExceptionHandler({IllegalArgumentException.class, MissingServletRequestParameterException.class,
        MultipartException.class})
    public ModelAndView badRequest() {
        return error(HttpStatus.BAD_REQUEST);
    }

    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ModelAndView payloadTooLarge() {
        return error(HttpStatus.PAYLOAD_TOO_LARGE);
    }

    private ModelAndView error(HttpStatus status) {
        ModelAndView view = new ModelAndView("error");
        view.setStatus(status);
        view.addObject("status", status.value());
        return view;
    }
}
