package com.example.clinic.config.freemarker;

import java.text.DecimalFormat;

public class TemplateNumbers {

    public String formatInteger(Number value) {
        return new DecimalFormat("#,##0").format(value);
    }
}
