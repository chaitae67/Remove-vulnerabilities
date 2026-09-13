package com.example.clinic.config.freemarker;

public class TemplateStrings {

    /** 별점 등 반복 출력용. 값이 없거나 횟수가 0 이하면 빈 문자열을 돌려준다. */
    public String repeat(String value, int times) {
        if (value == null || times <= 0) {
            return "";
        }
        return value.repeat(times);
    }
}
