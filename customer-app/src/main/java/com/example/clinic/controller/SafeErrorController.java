package com.example.clinic.controller;

import jakarta.servlet.RequestDispatcher;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.boot.web.servlet.error.ErrorController;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.servlet.ModelAndView;

/** EP-04: 오류 경로·예외명·메시지·스택트레이스를 응답에 포함하지 않는다. */
@Controller
public class SafeErrorController implements ErrorController {

    @RequestMapping("/error")
    public ModelAndView error(HttpServletRequest request) {
        int status = safeStatus(request.getAttribute(RequestDispatcher.ERROR_STATUS_CODE));
        ModelAndView view = new ModelAndView("error");
        view.setStatus(HttpStatus.valueOf(status));
        view.addObject("status", status);
        return view;
    }

    private int safeStatus(Object value) {
        if (value instanceof Integer code && HttpStatus.resolve(code) != null && code >= 400) {
            return code;
        }
        return HttpStatus.INTERNAL_SERVER_ERROR.value();
    }
}
