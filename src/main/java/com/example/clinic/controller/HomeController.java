package com.example.clinic.controller;

import java.security.Principal;
import java.time.LocalDate;
import org.springframework.format.annotation.DateTimeFormat;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

import com.example.clinic.service.NoticeService;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.QnaService;
import com.example.clinic.service.QuickConsultationService;
import com.example.clinic.service.UserService;

@Controller
public class HomeController {

    private final ProcedureService procedureService;
    private final NoticeService noticeService;
    private final QnaService qnaService;
    private final QuickConsultationService consultationService;
    private final UserService userService;

    public HomeController(ProcedureService procedureService, NoticeService noticeService, QnaService qnaService, QuickConsultationService consultationService, UserService userService) {
        this.procedureService = procedureService;
        this.noticeService = noticeService;
        this.qnaService = qnaService;
        this.consultationService = consultationService;
        this.userService = userService;
    }

    @GetMapping("/")
    public String home(Principal principal, Model model) {
        model.addAttribute("procedures", procedureService.findActiveProcedures());
        model.addAttribute("notices", noticeService.findLatest());
        model.addAttribute("qnas", qnaService.findLatest());
        model.addAttribute("minConsultationDate", LocalDate.now().toString());

        if (principal != null) {
            var currentUser = userService.findByUsername(principal.getName());
            model.addAttribute("currentUserId", currentUser.getId());
        }

        return "home";
    }

    @PostMapping("/consultations")
    public String createConsultation(
        @RequestParam String name,
        @RequestParam String phone,
        @RequestParam String area,
        @RequestParam String preferredContact,
        @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate preferredDate,
        @RequestParam(required = false) String message,
        @RequestParam(defaultValue = "false") boolean privacyAgreed,
        RedirectAttributes redirectAttributes
    ) {
        try {
            consultationService.create(name, phone, area, preferredContact, preferredDate, message, privacyAgreed);
            redirectAttributes.addFlashAttribute("message", "상담 신청이 접수되었습니다.");
        } catch (IllegalArgumentException ex) {
            redirectAttributes.addFlashAttribute("error", ex.getMessage());
        }
        return "redirect:/";
    }
}
