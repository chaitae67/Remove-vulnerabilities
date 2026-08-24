package com.example.clinic.controller;

import com.example.clinic.service.PaymentService;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.QnaService;
import com.example.clinic.service.QuickConsultationService;
import java.nio.charset.StandardCharsets;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminController {

    private final QuickConsultationService consultationService;
    private final PaymentService paymentService;
    private final QnaService qnaService;
    private final ProcedureService procedureService;

    public AdminController(QuickConsultationService consultationService, PaymentService paymentService, QnaService qnaService, ProcedureService procedureService) {
        this.consultationService = consultationService;
        this.paymentService = paymentService;
        this.qnaService = qnaService;
        this.procedureService = procedureService;
    }

    @GetMapping("/admin")
    public String dashboard(Model model) {
        model.addAttribute("consultations", consultationService.findRecentConsultations());
        model.addAttribute("orders", paymentService.findRecentOrders());
        model.addAttribute("qnas", qnaService.findAll());
        return "admin/dashboard";
    }

    @PostMapping("/admin/procedures/import")
    public String importProcedures(@RequestParam("file") MultipartFile file, RedirectAttributes redirectAttributes) {
        try {
            String xml = new String(file.getBytes(), StandardCharsets.UTF_8);
            int count = procedureService.importFromXml(xml);
            redirectAttributes.addFlashAttribute("message", count + "개의 시술 상품이 등록되었습니다.");
        } catch (Exception e) {
            redirectAttributes.addFlashAttribute("message", "XML 등록 실패: " + e.getMessage());
        }
        return "redirect:/admin";
    }
}
