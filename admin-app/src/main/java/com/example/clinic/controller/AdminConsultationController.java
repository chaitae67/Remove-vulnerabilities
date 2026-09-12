package com.example.clinic.controller;

import com.example.clinic.domain.QuickConsultation;
import com.example.clinic.service.QuickConsultationService;
import java.time.LocalDate;
import java.util.List;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminConsultationController {

    private final QuickConsultationService consultationService;

    public AdminConsultationController(QuickConsultationService consultationService) {
        this.consultationService = consultationService;
    }

    @GetMapping("/admin/consultations")
    public String list(@RequestParam(required = false) String keyword, Model model) {
        List<QuickConsultation> consultations = consultationService.search(keyword);
        model.addAttribute("consultations", consultations);
        model.addAttribute("keyword", keyword);
        return "admin/consultations";
    }

    @GetMapping("/admin/consultations/{id}")
    public String detail(@PathVariable Long id, Model model) {
        model.addAttribute("consultation", consultationService.findById(id));
        return "admin/consultation-detail";
    }

    @PostMapping("/admin/consultations/{id}")
    public String update(
        @PathVariable Long id,
        @RequestParam String name,
        @RequestParam String phone,
        @RequestParam(required = false) String area,
        @RequestParam(required = false) String preferredContact,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate preferredDate,
        @RequestParam(required = false) String message,
        @RequestParam(required = false) String adminNote,
        RedirectAttributes redirectAttributes
    ) {
        try {
            consultationService.update(id, name, phone, area, preferredContact, preferredDate, message, adminNote);
            redirectAttributes.addFlashAttribute("message", "상담 신청 내역이 수정되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/consultations/" + id;
    }

    @PostMapping("/admin/consultations/{id}/delete")
    public String delete(@PathVariable Long id, RedirectAttributes redirectAttributes) {
        try {
            consultationService.delete(id);
            redirectAttributes.addFlashAttribute("message", "상담 신청 내역이 삭제되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/consultations";
    }
}
