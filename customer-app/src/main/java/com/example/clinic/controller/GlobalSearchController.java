package com.example.clinic.controller;

import java.util.List;
import java.util.Locale;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

import com.example.clinic.domain.Notice;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.domain.Review;
import com.example.clinic.service.NoticeService;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.ReviewService;

@Controller
public class GlobalSearchController {
    private final ProcedureService procedureService;
    private final NoticeService noticeService;
    private final ReviewService reviewService;

    public GlobalSearchController(ProcedureService procedureService, NoticeService noticeService, ReviewService reviewService) {
        this.procedureService = procedureService;
        this.noticeService = noticeService;
        this.reviewService = reviewService;
    }

    @GetMapping("/search")
    public String search(@RequestParam(defaultValue = "") String keyword, Model model) {
        String query = keyword.trim().toLowerCase(Locale.ROOT);
        List<ProcedureProduct> procedures = query.isEmpty() ? List.of() : procedureService.findActiveProcedures().stream()
            .filter(item -> contains(item.getName(), query) || contains(item.getCategory(), query)
                || contains(item.getSummary(), query) || contains(item.getDescription(), query)).toList();
        List<Notice> notices = query.isEmpty() ? List.of() : noticeService.findAll().stream()
            .filter(item -> contains(item.getTitle(), query) || contains(item.getContent(), query)).toList();
        List<Review> reviews = query.isEmpty() ? List.of() : reviewService.findAll().stream()
            .filter(item -> contains(item.getTitle(), query) || contains(item.getContent(), query)).toList();

        model.addAttribute("keyword", keyword.trim());
        model.addAttribute("procedures", procedures);
        model.addAttribute("notices", notices);
        model.addAttribute("reviews", reviews);
        model.addAttribute("resultCount", procedures.size() + notices.size() + reviews.size());
        return "search/results";
    }

    private boolean contains(String value, String keyword) {
        return value != null && value.toLowerCase(Locale.ROOT).contains(keyword);
    }
}
