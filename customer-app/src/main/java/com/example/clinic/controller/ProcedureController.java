package com.example.clinic.controller;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

import com.example.clinic.repository.ProcedureSearchRepository;
import com.example.clinic.service.ProcedureService;

@Controller
public class ProcedureController {

    private final ProcedureService procedureService;
    private final ProcedureSearchRepository procedureSearchRepository;

    public ProcedureController(ProcedureService procedureService,
                                ProcedureSearchRepository procedureSearchRepository) {
        this.procedureService = procedureService;
        this.procedureSearchRepository = procedureSearchRepository;
    }

    @GetMapping("/procedures")
    public String list(@RequestParam(required = false) String keyword, Model model) {
        model.addAttribute("products", procedureSearchRepository.searchByName(keyword == null ? "" : keyword));
        model.addAttribute("keyword", keyword);
        return "procedures/list";
    }
}