package com.example.clinic.config.freemarker;

import java.time.format.DateTimeFormatter;
import java.time.temporal.TemporalAccessor;

public class TemplateTemporals {

    public String format(TemporalAccessor value, String pattern) {
        return DateTimeFormatter.ofPattern(pattern).format(value);
    }
}
