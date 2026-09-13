package com.example.clinic.config.freemarker;

import java.text.DecimalFormat;

public class TemplateNumbers {

    /** 값이 없으면 0으로 표시한다. (nullable 금액/포인트 컬럼 대응) */
    public String formatInteger(Number value) {
        return new DecimalFormat("#,##0").format(value == null ? 0 : value);
    }
}
