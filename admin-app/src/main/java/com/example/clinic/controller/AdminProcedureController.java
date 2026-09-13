package com.example.clinic.controller;

import com.example.clinic.service.ProcedureService;
import java.math.BigDecimal;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminProcedureController {

    private final ProcedureService procedureService;

    public AdminProcedureController(ProcedureService procedureService) {
        this.procedureService = procedureService;
    }

    @GetMapping("/admin/procedures")
    public String list(@RequestParam(required = false) String keyword, Model model) {
        model.addAttribute("procedures", procedureService.searchProcedures(keyword));
        model.addAttribute("keyword", keyword);
        return "admin/procedures";
    }

    @GetMapping("/admin/procedures/{id}")
    public String detail(@PathVariable Long id, Model model) {
        model.addAttribute("procedure", procedureService.findById(id));
        return "admin/procedure-detail";
    }

    @PostMapping("/admin/procedures/{id}")
    public String update(
        @PathVariable Long id,
        @RequestParam String name,
        @RequestParam(required = false) String category,
        @RequestParam(required = false) String summary,
        @RequestParam(required = false) String description,
        @RequestParam BigDecimal price,
        @RequestParam(defaultValue = "false") boolean active,
        RedirectAttributes redirectAttributes
    ) {
        try {
            procedureService.update(id, name, category, summary, description, price, active);
            redirectAttributes.addFlashAttribute("message", "시술/상담 패키지가 수정되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/procedures/" + id;
    }
}
