package com.example.clinic.controller;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

import com.example.clinic.repository.NoticeSearchRepository;
import com.example.clinic.repository.ProcedureSearchRepository;
import com.example.clinic.repository.ReviewSearchRepository;

@Controller
public class SearchController {

    private final NoticeSearchRepository noticeSearchRepository;
    private final ProcedureSearchRepository procedureSearchRepository;
    private final ReviewSearchRepository reviewSearchRepository;

    public SearchController(NoticeSearchRepository noticeSearchRepository,
                             ProcedureSearchRepository procedureSearchRepository,
                             ReviewSearchRepository reviewSearchRepository) {
        this.noticeSearchRepository = noticeSearchRepository;
        this.procedureSearchRepository = procedureSearchRepository;
        this.reviewSearchRepository = reviewSearchRepository;
    }

    @GetMapping("/notices/search")
    public String searchNotices(@RequestParam(required = false) String keyword, Model model) {
        model.addAttribute("notices", noticeSearchRepository.searchByTitle(keyword == null ? "" : keyword));
        model.addAttribute("keyword", keyword);
        return "notices/list";
    }

    @GetMapping("/procedures/search")
    public String searchProcedures(@RequestParam(required = false) String keyword, Model model) {
        try {
            model.addAttribute("products", procedureSearchRepository.searchByName(keyword == null ? "" : keyword));
        } catch (RuntimeException ex) {
            // IL-05: 예외 유형/SQLState/에러코드 등 내부 정보를 화면에 노출하지 않는다.
            return "error/database-error";
        }
        model.addAttribute("keyword", keyword);
        return "procedures/list";
    }

    @GetMapping("/reviews/search")
    public String searchReviews(@RequestParam(required = false) String keyword, Model model) {
        model.addAttribute("reviews", reviewSearchRepository.searchByTitle(keyword == null ? "" : keyword));
        model.addAttribute("keyword", keyword);
        return "reviews/list";
    }
}
