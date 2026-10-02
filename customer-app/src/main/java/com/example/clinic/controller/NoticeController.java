package com.example.clinic.controller;

import com.example.clinic.service.NoticeService;
import com.example.clinic.util.PrivacyMasker;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;

@Controller
public class NoticeController {

    private final NoticeService noticeService;
    public NoticeController(NoticeService noticeService) {
        this.noticeService = noticeService;
    }

    @GetMapping("/notices")
    public String list(Model model) {
        model.addAttribute("notices", noticeService.findAll());
        return "notices/list";
    }

    @GetMapping("/notices/{id}")
    public String detail(@PathVariable Long id, Model model) {
        var notice = noticeService.findById(id);
        model.addAttribute("notice", notice);
        model.addAttribute("maskedAuthor", PrivacyMasker.name(notice.getAuthor().getName()));
        return "notices/detail";
    }
}
