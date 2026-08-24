package com.example.clinic.controller;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

import com.example.clinic.repository.NoticeSearchRepository;
import com.example.clinic.repository.ProcedureSearchRepository;

@Controller
public class SearchController {

    private final NoticeSearchRepository noticeSearchRepository;
    private final ProcedureSearchRepository procedureSearchRepository;

    public SearchController(NoticeSearchRepository noticeSearchRepository,
                             ProcedureSearchRepository procedureSearchRepository) {
        this.noticeSearchRepository = noticeSearchRepository;
        this.procedureSearchRepository = procedureSearchRepository;
    }

    @GetMapping("/notices/search")
    public String searchNotices(@RequestParam(required = false) String keyword, Model model) {
        model.addAttribute("notices", noticeSearchRepository.searchByTitle(keyword == null ? "" : keyword));
        model.addAttribute("keyword", keyword);
        return "notices/list";
    }

    @GetMapping("/procedures/search")
    public String searchProcedures(@RequestParam(required = false) String keyword, Model model) {
        model.addAttribute("products", procedureSearchRepository.searchByName(keyword == null ? "" : keyword));
        model.addAttribute("keyword", keyword);
        return "procedures/list";
    }
}