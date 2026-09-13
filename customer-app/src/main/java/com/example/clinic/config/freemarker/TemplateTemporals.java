package com.example.clinic.config.freemarker;

import java.time.format.DateTimeFormatter;
import java.time.temporal.TemporalAccessor;

public class TemplateTemporals {

    /**
     * 값이 없으면 예외 대신 빈 문자열을 돌려준다.
     * (nullable 컬럼을 템플릿에서 그대로 넘겨도 화면 전체가 500으로 죽지 않도록)
     */
    public String format(TemporalAccessor value, String pattern) {
        if (value == null) {
            return "";
        }
        return DateTimeFormatter.ofPattern(pattern).format(value);
    }
}
